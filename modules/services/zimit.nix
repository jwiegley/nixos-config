{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Ports for services
  zimitPort = 5060;
  kiwixPort = 5061;

  # Directories
  archiveDir = "/tank/Archives";
  zimDir = "${archiveDir}/ZIM";
  workDir = "${archiveDir}/work";
  jobQueueDir = "/var/lib/zimit";

  # Python environment with dependencies
  pythonEnv = pkgs.python3.withPackages (
    ps: with ps; [
      flask
      gunicorn
    ]
  );

  # Python web UI for Zimit job management
  zimitWebUI = pkgs.python3.pkgs.buildPythonApplication {
    pname = "zimit-web-ui";
    version = "1.0.0";
    format = "other";

    propagatedBuildInputs = with pkgs.python3.pkgs; [
      flask
      gunicorn
    ];

    dontUnpack = true;
    dontBuild = true;

    installPhase = ''
            mkdir -p $out/bin $out/lib/zimit-web-ui

            # Create the Flask application
            cat > $out/lib/zimit-web-ui/app.py << 'FLASK_APP'
      #!/usr/bin/env python3
      """
      Zimit Web UI - A simple web interface for managing Zimit archive jobs.
      """

      import os
      import json
      import uuid
      import subprocess
      from datetime import datetime
      from pathlib import Path
      from flask import Flask, render_template_string, request, redirect, url_for, flash, jsonify

      app = Flask(__name__)
      app.secret_key = os.environ.get("FLASK_SECRET_KEY", "zimit-dev-key-change-in-production")

      # Configuration from environment
      JOB_QUEUE_DIR = Path(os.environ.get("JOB_QUEUE_DIR", "/var/lib/zimit"))
      ZIM_DIR = Path(os.environ.get("ZIM_DIR", "/tank/Archives/ZIM"))
      WORK_DIR = Path(os.environ.get("WORK_DIR", "/tank/Archives/work"))

      # Ensure directories exist
      JOB_QUEUE_DIR.mkdir(parents=True, exist_ok=True)

      # HTML Templates
      BASE_TEMPLATE = """
      <!DOCTYPE html>
      <html lang="en">
      <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>Zimit - Web Archive Manager</title>
          <style>
              :root {
                  --bg-color: #1a1a2e;
                  --card-bg: #16213e;
                  --accent: #0f3460;
                  --text: #e4e4e4;
                  --text-muted: #8a8a8a;
                  --success: #4ade80;
                  --warning: #fbbf24;
                  --error: #f87171;
                  --info: #60a5fa;
              }
              * { box-sizing: border-box; margin: 0; padding: 0; }
              body {
                  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
                  background: var(--bg-color);
                  color: var(--text);
                  line-height: 1.6;
                  padding: 2rem;
              }
              .container { max-width: 1200px; margin: 0 auto; }
              h1, h2, h3 { margin-bottom: 1rem; }
              h1 { color: var(--info); }
              .card {
                  background: var(--card-bg);
                  border-radius: 8px;
                  padding: 1.5rem;
                  margin-bottom: 1.5rem;
                  box-shadow: 0 4px 6px rgba(0,0,0,0.3);
              }
              .form-group { margin-bottom: 1rem; }
              label { display: block; margin-bottom: 0.5rem; color: var(--text-muted); }
              input[type="text"], input[type="url"], input[type="number"], select, textarea {
                  width: 100%;
                  padding: 0.75rem;
                  border: 1px solid var(--accent);
                  border-radius: 4px;
                  background: var(--bg-color);
                  color: var(--text);
                  font-size: 1rem;
              }
              input:focus, select:focus, textarea:focus {
                  outline: none;
                  border-color: var(--info);
              }
              button, .btn {
                  padding: 0.75rem 1.5rem;
                  border: none;
                  border-radius: 4px;
                  cursor: pointer;
                  font-size: 1rem;
                  transition: opacity 0.2s;
                  text-decoration: none;
                  display: inline-block;
              }
              button:hover, .btn:hover { opacity: 0.9; }
              .btn-primary { background: var(--info); color: #000; }
              .btn-success { background: var(--success); color: #000; }
              .btn-danger { background: var(--error); color: #000; }
              .btn-warning { background: var(--warning); color: #000; }
              .status-badge {
                  padding: 0.25rem 0.75rem;
                  border-radius: 9999px;
                  font-size: 0.875rem;
                  font-weight: 500;
              }
              .status-pending { background: var(--warning); color: #000; }
              .status-running { background: var(--info); color: #000; }
              .status-completed { background: var(--success); color: #000; }
              .status-failed { background: var(--error); color: #000; }
              table { width: 100%; border-collapse: collapse; }
              th, td { padding: 1rem; text-align: left; border-bottom: 1px solid var(--accent); }
              th { color: var(--text-muted); font-weight: 500; }
              .flash { padding: 1rem; border-radius: 4px; margin-bottom: 1rem; }
              .flash-success { background: var(--success); color: #000; }
              .flash-error { background: var(--error); color: #000; }
              .flash-info { background: var(--info); color: #000; }
              .nav { display: flex; gap: 1rem; margin-bottom: 2rem; }
              .nav a { color: var(--text); text-decoration: none; padding: 0.5rem 1rem; border-radius: 4px; }
              .nav a:hover, .nav a.active { background: var(--accent); }
              .file-list { list-style: none; }
              .file-list li { padding: 0.75rem; border-bottom: 1px solid var(--accent); display: flex; justify-content: space-between; align-items: center; }
              .file-list li:last-child { border-bottom: none; }
              .file-size { color: var(--text-muted); font-size: 0.875rem; }
              .inline-form { display: inline; }
              .help-text { font-size: 0.875rem; color: var(--text-muted); margin-top: 0.25rem; }
          </style>
      </head>
      <body>
          <div class="container">
              <h1>Zimit Web Archive Manager</h1>
              <nav class="nav">
                  <a href="/" class="{{ "active" if active_page == "home" else "" }}">New Job</a>
                  <a href="/jobs" class="{{ "active" if active_page == "jobs" else "" }}">Job Queue</a>
                  <a href="/archives" class="{{ "active" if active_page == "archives" else "" }}">Archives</a>
              </nav>
              {% with messages = get_flashed_messages(with_categories=true) %}
                  {% for category, message in messages %}
                      <div class="flash flash-{{ category }}">{{ message }}</div>
                  {% endfor %}
              {% endwith %}
              {{ content|safe }}
          </div>
      </body>
      </html>
      """

      HOME_CONTENT = """
      <div class="card">
          <h2>Create New Archive Job</h2>
          <form method="POST" action="/submit">
              <div class="form-group">
                  <label for="url">Website URL</label>
                  <input type="url" id="url" name="url" required placeholder="https://example.com">
                  <p class="help-text">The starting URL to archive. The crawler will follow links from this page.</p>
              </div>
              <div class="form-group">
                  <label for="name">Archive Name</label>
                  <input type="text" id="name" name="name" required placeholder="example-site">
                  <p class="help-text">Name for the ZIM file (without extension). Use lowercase and hyphens.</p>
              </div>
              <div class="form-group">
                  <label for="title">Title</label>
                  <input type="text" id="title" name="title" required placeholder="Example Site Documentation">
                  <p class="help-text">Display title shown in Kiwix library. Make it descriptive!</p>
              </div>
              <div class="form-group">
                  <label for="description">Description (optional)</label>
                  <input type="text" id="description" name="description" placeholder="Official documentation for Example" maxlength="30">
                  <p class="help-text">Short description (max 30 chars) shown in Kiwix library.</p>
              </div>
              <div class="form-group">
                  <label for="favicon">Favicon URL (optional)</label>
                  <input type="url" id="favicon" name="favicon" placeholder="https://example.com/favicon.ico">
                  <p class="help-text">URL to favicon/icon for Kiwix library thumbnail. If not set, auto-detected from site.</p>
              </div>
              <div class="form-group">
                  <label for="scope_type">Scope Type</label>
                  <select id="scope_type" name="scope_type">
                      <option value="host" selected>Host (recommended) - All pages on same domain</option>
                      <option value="prefix">Prefix - Only URLs starting with seed URL</option>
                      <option value="domain">Domain - Include subdomains</option>
                      <option value="page">Page - Single page only</option>
                  </select>
                  <p class="help-text">How broadly to crawl from the seed URL.</p>
              </div>
              <div class="form-group">
                  <label for="workers">Workers</label>
                  <input type="number" id="workers" name="workers" value="2" min="1" max="8">
                  <p class="help-text">Number of parallel crawl workers (1-8). More workers = faster but more resource intensive.</p>
              </div>
              <div class="form-group">
                  <label for="page_limit">Page Limit (optional)</label>
                  <input type="number" id="page_limit" name="page_limit" placeholder="Leave empty for unlimited">
                  <p class="help-text">Maximum number of pages to archive. Leave empty to archive the entire site.</p>
              </div>
              <div class="form-group">
                  <label for="scope_regex">Exclude Pattern (optional)</label>
                  <input type="text" id="scope_regex" name="scope_regex" placeholder="(\?q=|/search|/login)">
                  <p class="help-text">Regex pattern for URLs to exclude from crawling.</p>
              </div>
              <button type="submit" class="btn btn-primary">Submit Job</button>
          </form>
      </div>
      """

      JOBS_CONTENT = """
      <div class="card">
          <h2>Job Queue</h2>
          {% if jobs %}
          <table>
              <thead>
                  <tr>
                      <th>Name</th>
                      <th>URL</th>
                      <th>Status</th>
                      <th>Created</th>
                      <th>Actions</th>
                  </tr>
              </thead>
              <tbody>
                  {% for job in jobs %}
                  <tr>
                      <td>{{ job.name }}</td>
                      <td><a href="{{ job.url }}" target="_blank" style="color: var(--info);">{{ job.url[:50] }}...</a></td>
                      <td><span class="status-badge status-{{ job.status }}">{{ job.status }}</span></td>
                      <td>{{ job.created }}</td>
                      <td>
                          {% if job.status == "pending" %}
                          <form method="POST" action="/cancel/{{ job.id }}" class="inline-form">
                              <button type="submit" class="btn btn-danger" style="padding: 0.25rem 0.75rem;">Cancel</button>
                          </form>
                          {% elif job.status == "failed" %}
                          <form method="POST" action="/retry/{{ job.id }}" class="inline-form">
                              <button type="submit" class="btn btn-warning" style="padding: 0.25rem 0.75rem;">Retry</button>
                          </form>
                          {% endif %}
                      </td>
                  </tr>
                  {% endfor %}
              </tbody>
          </table>
          {% else %}
          <p style="color: var(--text-muted);">No jobs in queue. Submit a new job to get started.</p>
          {% endif %}
      </div>
      """

      ARCHIVES_CONTENT = """
      <div class="card">
          <h2>ZIM Archives</h2>
          <p style="margin-bottom: 1rem; color: var(--text-muted);">
              Browse archives with <a href="https://kiwix.vulcan.lan" style="color: var(--info);">Kiwix</a>
          </p>
          {% if archives %}
          <ul class="file-list">
              {% for archive in archives %}
              <li>
                  <span>{{ archive.name }}</span>
                  <span class="file-size">{{ archive.size }}</span>
              </li>
              {% endfor %}
          </ul>
          {% else %}
          <p style="color: var(--text-muted);">No archives yet. Create a job to start archiving websites.</p>
          {% endif %}
      </div>
      """

      def load_jobs():
          """Load all jobs from the queue directory."""
          jobs = []
          jobs_dir = JOB_QUEUE_DIR / "jobs"
          if jobs_dir.exists():
              for job_file in sorted(jobs_dir.glob("*.json"), key=lambda x: x.stat().st_mtime, reverse=True):
                  try:
                      with open(job_file) as f:
                          job = json.load(f)
                          job["id"] = job_file.stem
                          jobs.append(job)
                  except Exception:
                      pass
          return jobs

      def save_job(job_id, job_data):
          """Save a job to the queue directory."""
          jobs_dir = JOB_QUEUE_DIR / "jobs"
          jobs_dir.mkdir(parents=True, exist_ok=True)
          with open(jobs_dir / f"{job_id}.json", "w") as f:
              json.dump(job_data, f, indent=2)

      def get_archives():
          """List all ZIM files in the archive directory."""
          archives = []
          if ZIM_DIR.exists():
              for zim_file in sorted(ZIM_DIR.glob("*.zim"), key=lambda x: x.stat().st_mtime, reverse=True):
                  size = zim_file.stat().st_size
                  if size > 1024 * 1024 * 1024:
                      size_str = f"{size / (1024 * 1024 * 1024):.1f} GB"
                  elif size > 1024 * 1024:
                      size_str = f"{size / (1024 * 1024):.1f} MB"
                  else:
                      size_str = f"{size / 1024:.1f} KB"
                  archives.append({
                      "name": zim_file.name,
                      "size": size_str,
                      "path": str(zim_file)
                  })
          return archives

      @app.route("/")
      def home():
          content = render_template_string(HOME_CONTENT)
          return render_template_string(BASE_TEMPLATE, active_page="home", content=content)

      @app.route("/submit", methods=["POST"])
      def submit_job():
          url = request.form.get("url", "").strip()
          name = request.form.get("name", "").strip().lower().replace(" ", "-")
          title = request.form.get("title", "").strip()
          description = request.form.get("description", "").strip()[:30]  # Max 30 chars
          favicon = request.form.get("favicon", "").strip()
          scope_type = request.form.get("scope_type", "host").strip()
          workers = int(request.form.get("workers", 2))
          page_limit = request.form.get("page_limit", "").strip()
          scope_regex = request.form.get("scope_regex", "").strip()

          if not url or not name or not title:
              flash("URL, name, and title are required", "error")
              return redirect(url_for("home"))

          job_id = str(uuid.uuid4())[:8]
          job_data = {
              "url": url,
              "name": name,
              "title": title,
              "description": description if description else None,
              "favicon": favicon if favicon else None,
              "scope_type": scope_type,
              "workers": workers,
              "page_limit": int(page_limit) if page_limit else None,
              "scope_regex": scope_regex if scope_regex else None,
              "status": "pending",
              "created": datetime.now().isoformat(),
              "started": None,
              "completed": None,
              "error": None
          }
          save_job(job_id, job_data)
          flash(f"Job submitted successfully!", "success")
          return redirect(url_for("jobs"))

      @app.route("/jobs")
      def jobs():
          job_list = load_jobs()
          content = render_template_string(JOBS_CONTENT, jobs=job_list)
          return render_template_string(BASE_TEMPLATE, active_page="jobs", content=content)

      @app.route("/cancel/<job_id>", methods=["POST"])
      def cancel_job(job_id):
          job_file = JOB_QUEUE_DIR / "jobs" / f"{job_id}.json"
          if job_file.exists():
              job_file.unlink()
              flash("Job cancelled", "info")
          return redirect(url_for("jobs"))

      @app.route("/retry/<job_id>", methods=["POST"])
      def retry_job(job_id):
          job_file = JOB_QUEUE_DIR / "jobs" / f"{job_id}.json"
          if job_file.exists():
              with open(job_file) as f:
                  job = json.load(f)
              job["status"] = "pending"
              job["error"] = None
              job["started"] = None
              job["completed"] = None
              with open(job_file, "w") as f:
                  json.dump(job, f, indent=2)
              flash("Job requeued", "success")
          return redirect(url_for("jobs"))

      @app.route("/archives")
      def archives():
          archive_list = get_archives()
          content = render_template_string(ARCHIVES_CONTENT, archives=archive_list)
          return render_template_string(BASE_TEMPLATE, active_page="archives", content=content)

      @app.route("/api/health")
      def health():
          return jsonify({"status": "ok", "jobs": len(load_jobs()), "archives": len(get_archives())})

      @app.route("/metrics")
      def metrics():
          """Prometheus metrics endpoint."""
          jobs = load_jobs()
          archives = get_archives()

          pending = sum(1 for j in jobs if j["status"] == "pending")
          running = sum(1 for j in jobs if j["status"] == "running")
          completed = sum(1 for j in jobs if j["status"] == "completed")
          failed = sum(1 for j in jobs if j["status"] == "failed")

          total_size = sum(Path(a["path"]).stat().st_size for a in archives if Path(a["path"]).exists())

          metrics_output = f"""# HELP zimit_jobs_total Total number of jobs by status
      # TYPE zimit_jobs_total gauge
      zimit_jobs_pending {pending}
      zimit_jobs_running {running}
      zimit_jobs_completed {completed}
      zimit_jobs_failed {failed}
      # HELP zimit_archives_total Total number of ZIM archives
      # TYPE zimit_archives_total gauge
      zimit_archives_total {len(archives)}
      # HELP zimit_archives_size_bytes Total size of ZIM archives in bytes
      # TYPE zimit_archives_size_bytes gauge
      zimit_archives_size_bytes {total_size}
      """
          return metrics_output, 200, {"Content-Type": "text/plain"}

      if __name__ == "__main__":
          app.run(host="127.0.0.1", port=5060, debug=False)
      FLASK_APP

            # Create the runner script with explicit paths using the Python environment
            cat > $out/bin/zimit-web-ui << RUNNER
      #!${pkgs.bash}/bin/bash
      cd $out/lib/zimit-web-ui
      exec ${pythonEnv}/bin/gunicorn \\
          --bind 127.0.0.1:5060 \\
          --workers 2 \\
          --timeout 120 \\
          --access-logfile - \\
          --error-logfile - \\
          app:app
      RUNNER
            chmod +x $out/bin/zimit-web-ui
    '';

    meta = {
      description = "Web UI for managing Zimit archive jobs";
      mainProgram = "zimit-web-ui";
    };
  };

  # Zimit job runner script (runs pending jobs)
  zimitJobRunner = pkgs.writeShellApplication {
    name = "zimit-job-runner";
    runtimeInputs = with pkgs; [
      jq
      coreutils
      podman
    ];
    text = ''
      set -euo pipefail

      # Ensure newuidmap/newgidmap are found (required for rootless podman)
      export PATH="/run/wrappers/bin:$PATH"

      JOB_QUEUE_DIR="${jobQueueDir}"
      ZIM_DIR="${zimDir}"
      WORK_DIR="${workDir}"
      JOBS_DIR="$JOB_QUEUE_DIR/jobs"

      log() {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
      }

      # Ensure directories exist
      mkdir -p "$JOBS_DIR" "$ZIM_DIR" "$WORK_DIR"

      # Find pending jobs
      for job_file in "$JOBS_DIR"/*.json; do
        [ -f "$job_file" ] || continue

        status=$(jq -r '.status' "$job_file")
        [ "$status" = "pending" ] || continue

        job_id=$(basename "$job_file" .json)
        log "Processing job: $job_id"

        # Update status to running
        jq '.status = "running" | .started = now | .started = (now | strftime("%Y-%m-%dT%H:%M:%S"))' "$job_file" > "$job_file.tmp" && mv "$job_file.tmp" "$job_file"

        # Extract job parameters
        url=$(jq -r '.url' "$job_file")
        name=$(jq -r '.name' "$job_file")
        title=$(jq -r '.title // empty' "$job_file")
        description=$(jq -r '.description // empty' "$job_file")
        favicon=$(jq -r '.favicon // empty' "$job_file")
        workers=$(jq -r '.workers // 2' "$job_file")
        page_limit=$(jq -r '.page_limit // empty' "$job_file")
        scope_regex=$(jq -r '.scope_regex // empty' "$job_file")
        scope_type=$(jq -r '.scope_type // "host"' "$job_file")

        # Build Zimit command arguments
        zimit_args=(
          "--seeds" "$url"
          "--name" "$name"
          "--workers" "$workers"
          "--output" "/output"
          # Enable state saving for crash recovery
          "--saveState" "always"
          "--saveStateInterval" "300"
          # Assume restarts on error - don't run post-crawl on interrupt
          "--restartsOnError"
          # Increase behavior timeout for MathJax-heavy pages
          "--behaviorTimeout" "180"
        )

        # Title is required for proper Kiwix display
        if [ -n "$title" ] && [ "$title" != "null" ]; then
          zimit_args+=("--title" "$title")
        else
          # Fallback to name if no title provided
          zimit_args+=("--title" "$name")
        fi

        # Description (max 30 chars) for Kiwix library
        if [ -n "$description" ] && [ "$description" != "null" ]; then
          zimit_args+=("--description" "$description")
        fi

        # Favicon URL for Kiwix library thumbnail
        if [ -n "$favicon" ] && [ "$favicon" != "null" ]; then
          zimit_args+=("--favicon" "$favicon")
        fi

        if [ -n "$page_limit" ] && [ "$page_limit" != "null" ]; then
          zimit_args+=("--pageLimit" "$page_limit")
        fi

        if [ -n "$scope_regex" ] && [ "$scope_regex" != "null" ]; then
          zimit_args+=("--scopeExcludeRx" "$scope_regex")
        fi

        # Scope type: page, page-spa, prefix, host, domain, any
        if [ -n "$scope_type" ] && [ "$scope_type" != "null" ]; then
          zimit_args+=("--scopeType" "$scope_type")
        fi

        log "Running Zimit for $url with args: ''${zimit_args[*]}"

        # Create work directory for this job
        job_work_dir="$WORK_DIR/$job_id"
        mkdir -p "$job_work_dir"

        # Run Zimit container (using locally-built ARM64 image)
        # Note: shm-size increased to 16GB to prevent browser crashes on large crawls
        # CHROME_FLAGS increases V8 heap for MathJax-heavy sites like ncatlab
        if podman run --rm \
          -v "$job_work_dir:/output" \
          --shm-size=16gb \
          -e "CHROME_FLAGS=--max-old-space-size=8192 --disable-dev-shm-usage" \
          localhost/zimit:arm64 \
          zimit "''${zimit_args[@]}" 2>&1 | tee "$job_work_dir/zimit.log"; then

          log "Zimit completed successfully for $name"

          # Move ZIM file to archive directory
          for zim in "$job_work_dir"/*.zim; do
            [ -f "$zim" ] || continue
            mv "$zim" "$ZIM_DIR/"
            log "Moved $(basename "$zim") to $ZIM_DIR"
          done

          # Update job status
          jq '.status = "completed" | .completed = (now | strftime("%Y-%m-%dT%H:%M:%S"))' "$job_file" > "$job_file.tmp" && mv "$job_file.tmp" "$job_file"

          # Clean up work directory
          rm -rf "$job_work_dir"
        else
          log "Zimit failed for $name"
          error_msg=$(tail -20 "$job_work_dir/zimit.log" 2>/dev/null || echo "Unknown error")
          jq --arg err "$error_msg" '.status = "failed" | .error = $err | .completed = (now | strftime("%Y-%m-%dT%H:%M:%S"))' "$job_file" > "$job_file.tmp" && mv "$job_file.tmp" "$job_file"
        fi
      done

      log "Job runner completed"
    '';
  };

  # Progress monitor script - updates job status from running containers
  zimitProgressMonitor = pkgs.writeShellApplication {
    name = "zimit-progress-monitor";
    runtimeInputs = with pkgs; [
      jq
      coreutils
      podman
      gnugrep
      gawk
    ];
    text = ''
      set -euo pipefail

      # Ensure newuidmap/newgidmap are found (required for rootless podman)
      export PATH="/run/wrappers/bin:$PATH"

      JOB_QUEUE_DIR="${jobQueueDir}"
      WORK_DIR="${workDir}"
      JOBS_DIR="$JOB_QUEUE_DIR/jobs"
      PROGRESS_FILE="$JOB_QUEUE_DIR/progress.json"

      log() {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
      }

      log "Starting progress monitor"

      # Initialize progress file
      echo '{"updated": "'"$(date -Iseconds)"'", "jobs": []}' > "$PROGRESS_FILE.tmp"

      # Check for running zimit containers
      running_containers=$(podman ps --format '{{.Names}} {{.ID}}' 2>/dev/null | grep -v "^$" || true)

      if [ -z "$running_containers" ]; then
        log "No running containers found"
        # Check for orphaned "running" jobs and collect their info from log files
        for job_file in "$JOBS_DIR"/*.json; do
          [ -f "$job_file" ] || continue
          status=$(jq -r '.status' "$job_file")
          [ "$status" = "running" ] || continue

          job_id=$(basename "$job_file" .json)
          job_name=$(jq -r '.name' "$job_file")
          log_file="$WORK_DIR/$job_id/zimit.log"

          if [ -f "$log_file" ]; then
            # Get last progress from log file
            last_progress=$(grep -o '"crawled":[0-9]*,"total":[0-9]*' "$log_file" 2>/dev/null | tail -1 || echo "")
            if [ -n "$last_progress" ]; then
              crawled=$(echo "$last_progress" | grep -o '"crawled":[0-9]*' | grep -o '[0-9]*')
              total=$(echo "$last_progress" | grep -o '"total":[0-9]*' | grep -o '[0-9]*')
              percent=$(awk "BEGIN {if ($total > 0) printf \"%.1f\", ($crawled/$total)*100; else print \"0\"}")
              log "Job $job_name: $crawled/$total pages ($percent%) - FROM LOG FILE (no container running)"

              # Update job file with progress info
              jq --arg crawled "$crawled" --arg total "$total" --arg percent "$percent" \
                '.progress = {crawled: ($crawled|tonumber), total: ($total|tonumber), percent: ($percent|tonumber), updated: (now | strftime("%Y-%m-%dT%H:%M:%S")), source: "log_file", warning: "No container running - job may be orphaned"}' \
                "$job_file" > "$job_file.tmp" && mv "$job_file.tmp" "$job_file"
            fi
          fi
        done
        mv "$PROGRESS_FILE.tmp" "$PROGRESS_FILE"
        log "Progress monitor completed"
        exit 0
      fi

      log "Found running containers: $running_containers"

      # Process each running container
      echo "$running_containers" | while read -r container_name container_id; do
        log "Checking container: $container_name ($container_id)"

        # Get the command to find which job this is
        container_cmd=$(podman inspect "$container_id" --format '{{.Config.Cmd}}' 2>/dev/null || echo "")

        # Extract job name from zimit command
        job_name=$(echo "$container_cmd" | grep -oP '(?<=--name )[^ \]]+' | head -1 || echo "unknown")

        if [ "$job_name" = "unknown" ]; then
          log "Could not determine job name for container $container_name"
          continue
        fi

        log "Container is running job: $job_name"

        # Find the job file by name
        job_file=""
        job_id=""
        for f in "$JOBS_DIR"/*.json; do
          [ -f "$f" ] || continue
          if [ "$(jq -r '.name' "$f")" = "$job_name" ] && [ "$(jq -r '.status' "$f")" = "running" ]; then
            job_file="$f"
            job_id=$(basename "$f" .json)
            break
          fi
        done

        if [ -z "$job_file" ]; then
          log "No matching job file found for $job_name"
          continue
        fi

        log "Found job file: $job_file (id: $job_id)"

        # Get progress from work directory log file (primary source)
        log_file="$WORK_DIR/$job_id/zimit.log"
        last_progress=""

        if [ -f "$log_file" ]; then
          last_progress=$(grep -o '"crawled":[0-9]*,"total":[0-9]*' "$log_file" 2>/dev/null | tail -1 || echo "")
          log "Reading progress from log file: $log_file"
        fi

        # Fallback to container logs if log file has no progress
        if [ -z "$last_progress" ]; then
          last_progress=$(podman logs --tail 1000 "$container_id" 2>&1 | grep -o '"crawled":[0-9]*,"total":[0-9]*' | tail -1 || echo "")
          [ -n "$last_progress" ] && log "Got progress from container logs"
        fi

        if [ -n "$last_progress" ]; then
          crawled=$(echo "$last_progress" | grep -o '"crawled":[0-9]*' | grep -o '[0-9]*')
          total=$(echo "$last_progress" | grep -o '"total":[0-9]*' | grep -o '[0-9]*')
          percent=$(awk "BEGIN {if ($total > 0) printf \"%.1f\", ($crawled/$total)*100; else print \"0\"}")

          log "Job $job_name: $crawled/$total pages ($percent%)"

          # Update job file with progress info
          jq --arg crawled "$crawled" --arg total "$total" --arg percent "$percent" --arg container "$container_name" \
            '.progress = {crawled: ($crawled|tonumber), total: ($total|tonumber), percent: ($percent|tonumber), updated: (now | strftime("%Y-%m-%dT%H:%M:%S")), container: $container, source: "log_file"}' \
            "$job_file" > "$job_file.tmp" && mv "$job_file.tmp" "$job_file"
        else
          log "No progress info found for $job_name"
        fi
      done

      mv "$PROGRESS_FILE.tmp" "$PROGRESS_FILE"
      log "Progress monitor completed"
    '';
  };

  # Script to generate nginx URL mapping for ZIM files with cache-busting query strings
  # This fixes the issue where dynamically generated download links don't include query strings
  kiwixUrlMapGenerator = pkgs.writeShellApplication {
    name = "kiwix-url-map-generator";
    runtimeInputs = with pkgs; [
      zim-tools
      coreutils
      gnused
      gnugrep
    ];
    text = ''
      set -euo pipefail

      ZIM_DIR="${zimDir}"
      MAP_FILE="/var/lib/nginx/kiwix-url-map.conf"
      TEMP_MAP=$(mktemp)

      log() {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
      }

      log "Generating Kiwix URL mapping file..."

      # Start the map file
      echo "# Auto-generated by kiwix-url-map-generator" > "$TEMP_MAP"
      echo "# Maps URLs without cache-buster query strings to URLs with them" >> "$TEMP_MAP"
      echo "" >> "$TEMP_MAP"

      for zim_file in "$ZIM_DIR"/*.zim; do
        [ -f "$zim_file" ] || continue

        zim_name=$(basename "$zim_file" .zim)
        log "Processing $zim_name..."

        # Extract URLs with query strings (pdf, docx, xhtml files)
        zimdump list "$zim_file" 2>/dev/null | \
          grep -E '\.(pdf|docx|xhtml)\?' | \
          while read -r url; do
            # Extract base URL (without query string) using parameter expansion
            base=''${url%%\?*}
            # URL-encode the question mark as %3F for kiwix-serve
            # kiwix-serve treats ? as query string separator, but in ZIM it's part of the path
            encoded_url=''${url/\?/%3F}
            # Format: /content/zim-name/base -> /content/zim-name/encoded-full
            echo "/content/$zim_name/$base /content/$zim_name/$encoded_url;" >> "$TEMP_MAP"
          done || true
      done

      # Count mappings
      count=$(grep -c ';$' "$TEMP_MAP" || echo 0)
      log "Generated $count URL mappings"

      # Move to final location
      mv "$TEMP_MAP" "$MAP_FILE"
      chmod 644 "$MAP_FILE"

      log "URL mapping file written to $MAP_FILE"
    '';
  };

in
{
  # Create zimit system user with subuid/subgid for rootless podman
  users.users.zimit = {
    isSystemUser = true;
    group = "zimit";
    home = "/var/lib/zimit";
    createHome = true;
    shell = pkgs.bash;
    description = "Zimit web archive service user";
    extraGroups = [ "podman" ];
    subUidRanges = [
      {
        startUid = 100000;
        count = 65536;
      }
    ];
    subGidRanges = [
      {
        startGid = 100000;
        count = 65536;
      }
    ];
    linger = true; # Enable lingering for rootless podman
  };

  users.groups.zimit = { };

  # Add zimit to nix allowed-users for container operations
  nix.settings.allowed-users = lib.mkAfter [ "zimit" ];

  # Zimit Web UI service
  systemd.services.zimit-web-ui = {
    description = "Zimit Web UI for managing archive jobs";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];

    environment = {
      JOB_QUEUE_DIR = jobQueueDir;
      ZIM_DIR = zimDir;
      WORK_DIR = workDir;
      PYTHONPATH = "${zimitWebUI}/lib/zimit-web-ui";
    };

    serviceConfig = {
      Type = "simple";
      User = "zimit";
      Group = "zimit";
      WorkingDirectory = "${zimitWebUI}/lib/zimit-web-ui";
      ExecStart = "${zimitWebUI}/bin/zimit-web-ui";
      Restart = "always";
      RestartSec = 5;

      # Security hardening
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      NoNewPrivileges = true;
      ReadWritePaths = [
        jobQueueDir
        zimDir
        workDir
      ];
    };
  };

  # Zimit job runner timer (checks for pending jobs every 5 minutes)
  systemd.services.zimit-job-runner = {
    description = "Process pending Zimit archive jobs";
    after = [
      "network.target"
      "podman.socket"
    ];

    path = with pkgs; [
      podman
      jq
      coreutils
    ];

    environment = {
      JOB_QUEUE_DIR = jobQueueDir;
      ZIM_DIR = zimDir;
      WORK_DIR = workDir;
      # Required for rootless podman
      XDG_RUNTIME_DIR = "/run/user/929"; # zimit user ID
    };

    # Prevent nixos-rebuild from waiting on or interrupting long-running archive jobs
    restartIfChanged = false;
    stopIfChanged = false;

    serviceConfig = {
      Type = "oneshot";
      User = "zimit";
      Group = "zimit";
      ExecStart = lib.getExe zimitJobRunner;
      TimeoutStartSec = "30d"; # Allow up to 30 days for very large sites
      ReadWritePaths = [
        jobQueueDir
        zimDir
        workDir
      ];

      # Note: NoNewPrivileges disabled - required for podman user namespace mapping
      PrivateTmp = true;
    };
  };

  systemd.timers.zimit-job-runner = {
    description = "Timer for Zimit job runner";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      OnCalendar = "*:0/5"; # Every 5 minutes
      Persistent = true;
      RandomizedDelaySec = "30s";
    };
  };

  # Progress monitor service - updates job progress from running containers
  systemd.services.zimit-progress-monitor = {
    description = "Monitor Zimit job progress from running containers";
    after = [
      "network.target"
      "podman.socket"
    ];

    path = with pkgs; [
      podman
      jq
      coreutils
      gnugrep
      gawk
    ];

    environment = {
      JOB_QUEUE_DIR = jobQueueDir;
      WORK_DIR = workDir;
      XDG_RUNTIME_DIR = "/run/user/929"; # zimit user ID
    };

    serviceConfig = {
      Type = "oneshot";
      User = "zimit";
      Group = "zimit";
      ExecStart = lib.getExe zimitProgressMonitor;
      TimeoutStartSec = "5m";
      ReadWritePaths = [
        jobQueueDir
        workDir
      ];
      PrivateTmp = true;
    };
  };

  systemd.timers.zimit-progress-monitor = {
    description = "Timer for Zimit progress monitor";
    wantedBy = [ "timers.target" ];

    timerConfig = {
      OnCalendar = "*:0/15"; # Every 15 minutes
      Persistent = true;
      RandomizedDelaySec = "30s";
    };
  };

  # Kiwix-serve for browsing ZIM archives
  # Using a wrapper script to handle empty directory gracefully
  systemd.services.kiwix-serve =
    let
      kiwixStartScript = pkgs.writeShellScript "kiwix-serve-start" ''
        # Check if there are any ZIM files
        shopt -s nullglob
        zim_files=(${zimDir}/*.zim)

        if [ ''${#zim_files[@]} -eq 0 ]; then
          echo "No ZIM files found in ${zimDir}. Waiting for files..."
          # Just sleep and exit - systemd will restart us
          sleep 60
          exit 0
        fi

        # Note: Don't use --library flag when passing ZIM files directly
        exec ${pkgs.kiwix-tools}/bin/kiwix-serve \
          --port ${toString kiwixPort} \
          --nodatealiases \
          "''${zim_files[@]}"
      '';
    in
    {
      description = "Kiwix ZIM file server";
      after = [
        "network.target"
        "tank-Archives-ZIM.mount"
      ];
      wants = [ "tank-Archives-ZIM.mount" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "simple";
        User = "zimit";
        Group = "zimit";
        ExecStart = kiwixStartScript;
        Restart = "always";
        RestartSec = 30;

        # Security hardening
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        ReadOnlyPaths = [ zimDir ];
      };
    };

  # Ensure directories exist with proper permissions
  systemd.tmpfiles.rules = [
    "d ${jobQueueDir} 0750 zimit zimit -"
    "d ${jobQueueDir}/jobs 0750 zimit zimit -"
    "d ${zimDir} 0755 zimit zimit -"
    "d ${workDir} 0755 zimit zimit -"
    "d /var/lib/nginx 0755 nginx nginx -"
  ];

  # Create empty map file on first boot to avoid nginx errors
  # Need ReadWritePaths for /var/lib/nginx since nginx uses ProtectSystem=strict
  systemd.services.nginx.serviceConfig.ReadWritePaths = [ "/var/lib/nginx" ];
  systemd.services.nginx.preStart = lib.mkBefore ''
    if [ ! -f /var/lib/nginx/kiwix-url-map.conf ]; then
      mkdir -p /var/lib/nginx
      echo "# Empty map file - will be populated by kiwix-url-map-generator" > /var/lib/nginx/kiwix-url-map.conf
    fi
  '';

  # Kiwix URL map generator service - creates nginx map file for cache-buster redirects
  systemd.services.kiwix-url-map-generator = {
    description = "Generate Kiwix URL mapping for nginx";
    after = [
      "local-fs.target"
      "nginx.service"
    ];
    wants = [ "nginx.service" ];
    wantedBy = [ "multi-user.target" ];

    path = with pkgs; [
      zim-tools
      coreutils
      gnused
      gnugrep
    ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe kiwixUrlMapGenerator;
      # Reload nginx after updating the map file (use -f to not fail if nginx isn't running)
      ExecStartPost = "-${pkgs.systemd}/bin/systemctl reload nginx.service";
      User = "root";
      Group = "root";
      ReadOnlyPaths = [ zimDir ];
      ReadWritePaths = [ "/var/lib/nginx" ];
    };
  };

  # Regenerate URL map when ZIM files change (after new archives are created)
  # Use ExecStopPost with "+" prefix to run as root, since zimit-job-runner runs
  # as the unprivileged "zimit" user and cannot start system-level services.
  systemd.services.zimit-job-runner.serviceConfig.ExecStopPost = [
    "+${pkgs.systemd}/bin/systemctl start --no-block kiwix-url-map-generator.service"
  ];

  # Nginx configuration for Kiwix URL rewriting
  # Increase hash sizes for the large URL map (8000+ entries)
  services.nginx.mapHashMaxSize = 16384;
  services.nginx.mapHashBucketSize = 256;

  # Include the URL map file that redirects URLs without cache-busters to URLs with them
  services.nginx.appendHttpConfig = ''
    # Map URLs without cache-buster query strings to URLs with them
    # This file is generated by kiwix-url-map-generator service
    map $request_uri $kiwix_rewrite_uri {
      default "";
      include /var/lib/nginx/kiwix-url-map.conf;
    }
  '';

  # Nginx reverse proxies
  services.nginx.virtualHosts = {
    "zimit.vulcan.lan" = {
      forceSSL = true;
      sslCertificate = "/var/lib/nginx-certs/zimit.vulcan.lan.crt";
      sslCertificateKey = "/var/lib/nginx-certs/zimit.vulcan.lan.key";

      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString zimitPort}/";
        recommendedProxySettings = true;
      };
    };

    "kiwix.vulcan.lan" = {
      forceSSL = true;
      sslCertificate = "/var/lib/nginx-certs/kiwix.vulcan.lan.crt";
      sslCertificateKey = "/var/lib/nginx-certs/kiwix.vulcan.lan.key";

      # Redirect URLs without cache-busters to URLs with them
      extraConfig = ''
        # If we have a rewrite mapping for this URL, redirect to it
        if ($kiwix_rewrite_uri != "") {
          return 302 $kiwix_rewrite_uri;
        }
      '';

      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString kiwixPort}/";
        recommendedProxySettings = true;
      };
    };
  };

  # Firewall rules for localhost services
  networking.firewall.interfaces."lo".allowedTCPPorts = [
    zimitPort
    kiwixPort
  ];

  # Prometheus scrape config for Zimit metrics
  services.prometheus.scrapeConfigs = lib.mkIf config.services.prometheus.enable [
    {
      job_name = "zimit";
      static_configs = [
        {
          targets = [ "127.0.0.1:${toString zimitPort}" ];
          labels = {
            instance = "vulcan";
          };
        }
      ];
      metrics_path = "/metrics";
      scrape_interval = "60s";
    }
  ];

  # TODO: Prometheus alerting rules for Zimit
  # Currently disabled due to NixOS concatenating all rule files into one,
  # causing duplicate 'groups' keys. Need to restructure the alerting module.
  # Rules to add later:
  # - ZimitJobsFailed: Alert when failed jobs exist
  # - ZimitJobsStuck: Alert when jobs pending > 6h
  # - ZimitArchiveStorageLarge: Alert when storage > 100GB
}
