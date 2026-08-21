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
                  <input type="text" id="title" name="title" required placeholder="Example Site Documentation" maxlength="30">
                  <p class="help-text">Display title shown in Kiwix library (max 30 chars).</p>
              </div>
              <div class="form-group">
                  <label for="description">Description (optional)</label>
                  <input type="text" id="description" name="description" placeholder="Official documentation for Example" maxlength="80">
                  <p class="help-text">Short description (max 80 chars) shown in Kiwix library.</p>
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
          title = request.form.get("title", "").strip()[:30]  # Max 30 chars for ZIM metadata
          description = request.form.get("description", "").strip()[:80]  # Max 80 chars
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

          # PROGRESS FRESHNESS for running jobs (nixos-fdi).
          #
          # A crawl that HANGS while running was undetected: ZimitJobsStuck watches
          # zimit_jobs_pending, which is a queue that will not drain, and a hung
          # running job has pending=0. ServiceStuckActivating cannot help either --
          # the runner is a oneshot that sits in `activating` for the whole crawl, so
          # it was excluded after firing on every normal run.
          #
          # Duration is not a usable signal here: across 22 completed jobs legitimate
          # crawls ran from 26 MINUTES to 43 DAYS, so no threshold separates healthy
          # from hung. PROGRESS does separate them. The runner tees the crawl's output
          # to $WORK_DIR/<job_id>/zimit.log, so that file's mtime advances continuously
          # while pages are being fetched and stops dead when the crawl wedges.
          # Measured on a live crawl: mtime advanced 13s over a 12s sample and read 0s
          # old, against a 390G archive job that had been running for hours.
          #
          # Emitted only for RUNNING jobs, so the series disappears when nothing is
          # crawling and the paired alert cannot fire against an idle host.
          progress_lines = []
          now_ts = datetime.now().timestamp()
          for j in jobs:
              if j.get("status") != "running":
                  continue
              job_id = j.get("id") or ""
              log_path = WORK_DIR / job_id / "zimit.log"
              try:
                  age = now_ts - log_path.stat().st_mtime
              except OSError:
                  continue
              progress_lines.append(
                  'zimit_running_job_log_age_seconds{job_id="%s",name="%s"} %d'
                  % (job_id, j.get("name", ""), age)
              )
          if progress_lines:
              metrics_output += (
                  "# HELP zimit_running_job_log_age_seconds Seconds since the running job's crawl log was last written\n"
                  "# TYPE zimit_running_job_log_age_seconds gauge\n"
                  + "\n".join(progress_lines)
                  + "\n"
              )

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

      # Ensure podman storage uses /run/user/<uid> (not /tmp/storage-run-<uid>)
      # so it works from a system service where /tmp may be isolated.
      storage_conf="$HOME/.config/containers/storage.conf"
      mkdir -p "$(dirname "$storage_conf")"
      if [ ! -f "$storage_conf" ]; then
        cat > "$storage_conf" << STORAGEEOF
      [storage]
      driver = "overlay"
      runroot = "/run/user/$(id -u)/containers"
      STORAGEEOF
        log "Created podman storage.conf at $storage_conf"
      fi

      # Pre-flight: verify podman is functional before processing jobs
      if ! podman info >/dev/null 2>&1; then
        log "ERROR: podman is not functional, skipping job processing"
        log "$(podman info 2>&1 | tail -5)"
        exit 1
      fi

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

        # Title is required for proper Kiwix display (max 30 chars for ZIM metadata)
        if [ -n "$title" ] && [ "$title" != "null" ]; then
          if [ ''${#title} -gt 30 ]; then
            log "WARNING: Title '$title' exceeds 30 chars (''${#title}), truncating"
            title="''${title:0:30}"
          fi
          zimit_args+=("--title" "$title")
        else
          # Fallback to name if no title provided
          zimit_args+=("--title" "$name")
        fi

        # Description (max 80 chars) for Kiwix library
        if [ -n "$description" ] && [ "$description" != "null" ]; then
          if [ ''${#description} -gt 80 ]; then
            description="''${description:0:80}"
          fi
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
        # --network=host: Required because the job runner runs as a system service,
        # not a user service, so pasta/slirp4netns can't create their sandboxed
        # network namespaces.
        #
        # "Host networking is fine since zimit only needs outbound internet access"
        # was the original justification and it is INCOMPLETE — corrected 2026-08-20.
        # Host networking is not one-way: the container's own listeners bind the
        # host's interfaces too. Measured during a live crawl, this container binds
        # BOTH 0.0.0.0 and [::] on:
        #   6379  redis-server  browsertrix's crawl-state store, no auth
        #   6099  Xvfb          the X server behind headless Chrome
        # An unauthenticated Redis on a wildcard address is the classic RCE vector
        # (CONFIG SET dir + dbfilename to write arbitrary files), so this is worth
        # knowing about even though it is currently contained.
        #
        # IT IS CONTAINED BY THE HOST FIREWALL, verified rather than assumed: neither
        # port has an accept rule anywhere in iptables, NETAVARK_INPUT accepts only
        # DNS from 10.88.0.0/16 and so cannot bypass, and the nixos-fw chain
        # terminates in nixos-fw-log-refuse. Both ports are registered in
        # docs/ports.txt as TRANSIENT so the port-drift exporter stops flagging them
        # on every crawl.
        #
        # If this ever moves to a rootless user service, prefer a real network
        # namespace over --network=host and this whole exposure disappears.
        if podman run --rm \
          --network=host \
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
      systemd # systemctl, to check whether the job-runner is still alive
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

          # Reconcile orphaned jobs: a job still marked "running" with no
          # container is only truly orphaned if the job-runner is no longer
          # alive. A Type=oneshot runner stays "activating" for the entire
          # crawl, so treat both active and activating as alive; only inactive
          # or failed (host reboot, OOM kill) means the runner died before
          # writing a terminal status. Flip those to "failed" so the UI is
          # accurate. Gated this way, an in-flight crawl whose container is
          # briefly missed by "podman ps" is never wrongly failed.
          runner_state=$(systemctl is-active zimit-job-runner.service 2>/dev/null || true)
          if [ "$runner_state" != "active" ] && [ "$runner_state" != "activating" ]; then
            log "Job $job_name orphaned (running, no container, runner=$runner_state) - marking failed"
            jq --arg err "Orphaned: job-runner exited before completion (no container running, zimit-job-runner $runner_state). Auto-failed by progress-monitor." \
              '.status = "failed" | .error = $err | .completed = (now | strftime("%Y-%m-%dT%H:%M:%S"))' \
              "$job_file" > "$job_file.tmp" && mv "$job_file.tmp" "$job_file"
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
      gawk
      findutils # find, for the newer-than-map fast path
      diffutils # cmp, to detect a byte-identical regeneration
      systemd # systemctl, for the now-conditional nginx reload
    ];
    text = ''
      set -euo pipefail

      ZIM_DIR="${zimDir}"
      MAP_FILE="/var/lib/nginx/kiwix-url-map.conf"
      TEMP_MAP=$(mktemp)
      TEMP_ENTRIES=$(mktemp)

      log() {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
      }

      # ---- Fast path: skip everything when no ZIM has changed ------------
      # This generator is pulled in on every nginx start AND from
      # zimit-job-runner's ExecStopPost, which fires on EVERY 5-minute poll
      # regardless of whether that poll actually created an archive (its
      # comment claims "when ZIM files change", but nothing checked).
      # Measured 2026-08-02: 251 runs in one day at ~54s CPU each -- about
      # 3.8 CPU-hours -- and 252 nginx reloads (one per run; nginx itself never restarted).
      #
      # The CPU is the least of it. The scan zimdumps every ZIM off the USB
      # `tank` enclosure, whose bridge is known to hang under sustained load,
      # and nginx's worker_shutdown_timeout is 300s (web.nix), so reloading
      # every ~5 minutes keeps worker generations permanently overlapping and
      # terminates in-flight requests each time.
      #
      # The map is a pure function of the .zim set, so it only needs
      # recomputing when that set changes. Test the DIRECTORY mtime as well as
      # the files: a deleted ZIM leaves no newer file behind, so a file-only
      # test would serve stale entries forever.
      if [ -f "$MAP_FILE" ] \
         && [ ! "$ZIM_DIR" -nt "$MAP_FILE" ] \
         && [ -z "$(find "$ZIM_DIR" -maxdepth 1 -name '*.zim' -newer "$MAP_FILE" -print -quit 2>/dev/null)" ]; then
        log "No ZIM added, removed or changed since $MAP_FILE was written; nothing to do"
        rm -f "$TEMP_MAP" "$TEMP_ENTRIES"
        exit 0
      fi

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
            echo "/content/$zim_name/$base /content/$zim_name/$encoded_url;" >> "$TEMP_ENTRIES"
          done || true
      done

      # Deduplicate by map key (first field), keeping the first mapping seen.
      # One base URL can appear with several cache-buster query strings, which
      # would emit the same nginx map key twice; nginx then refuses to load the
      # map ("conflicting parameter") and fails to start. (Seen with the
      # afnan-library_* PDFs.)
      awk '!seen[$1]++' "$TEMP_ENTRIES" >> "$TEMP_MAP"
      rm -f "$TEMP_ENTRIES"

      # Count mappings
      count=$(grep -c ';$' "$TEMP_MAP" || echo 0)
      log "Generated $count URL mappings"

      # A ZIM's mtime can change without changing any URL it exposes (a touch,
      # an rsync re-copy, a restored snapshot), so the fast path above can let
      # us through and still produce a byte-identical map. Compare before
      # replacing, and reload nginx ONLY on a real change.
      if [ -f "$MAP_FILE" ] && cmp -s "$TEMP_MAP" "$MAP_FILE"; then
        log "Map unchanged ($count mappings); keeping $MAP_FILE, no nginx reload"
        rm -f "$TEMP_MAP"
        # Re-stamp so the fast path sees a map at least as new as every ZIM.
        # Without this a single touched ZIM would force a full rescan on every
        # trigger from here on -- exactly the loop this change exists to break.
        touch "$MAP_FILE"
        exit 0
      fi

      # Move to final location
      mv "$TEMP_MAP" "$MAP_FILE"
      chmod 644 "$MAP_FILE"

      log "URL mapping file written to $MAP_FILE"

      # Reload nginx HERE rather than from ExecStartPost, so it happens only
      # when the map actually changed. ExecStartPost ran unconditionally on
      # every successful invocation, which is where the 252 reloads/day came
      # from. --no-block: this unit is ordered after nginx.service so nginx is
      # up, but a oneshot has no reason to wait on the reload job.
      systemctl reload --no-block nginx.service \
        || log "WARNING: nginx reload failed; $MAP_FILE is still updated"
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

  # Ensure podman storage config directory exists for zimit user
  systemd.tmpfiles.settings."10-zimit-podman" = {
    "/var/lib/zimit/.config/containers" = {
      d = {
        user = "zimit";
        group = "zimit";
        mode = "0700";
      };
    };
  };

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
      Nice = 15;

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

  # Zimit job runner service (fired by the timer below, which checks for
  # pending jobs every 5 minutes)
  systemd.services.zimit-job-runner = {
    description = "Process pending Zimit archive jobs";
    after = [
      "network.target"
      "podman.socket"
    ];

    # Do not run unless the datasets this writes to are actually mounted.
    # Added 2026-08-20, after the llm-primer job (a03d993b) died with
    #   mkdir: cannot create directory '/tank/Archives/work/a03d993b': Permission denied
    # and zimit-progress-monitor then swept it as "Orphaned".
    #
    # /tank/Archives/ZIM and /tank/Archives/work are each their OWN ZFS dataset, not
    # plain directories under tank/Archives. This unit declared NO mount dependency
    # at all -- the tank-Archives-ZIM.mount after/wants further down this file
    # belongs to kiwix-serve, not to the runner -- so it was free to fire while
    # either dataset was unmounted.
    #
    # What prevented that from being much worse is worth writing down, because it
    # looks like the bug and is in fact the safety net: the directory SHADOWED
    # beneath the /tank/Archives/work mountpoint is root:root 0755, so an unmounted
    # run fails loudly with EACCES rather than silently writing a multi-GB crawl into
    # the parent dataset on the root pool. Do NOT "fix" this by making that shadowed
    # directory zimit-writable -- that trades a loud failure for silent data
    # misplacement and a filled root pool.
    #
    # RequiresMountsFor gives ORDERING, and on this host that is all it gives.
    # Verified after deploying it: `systemctl show -p After` gains
    # tank-Archives-work.mount and tank-Archives-ZIM.mount, but `-p Requires` still
    # lists only -.mount, and both mount units report RequiredBy=0 for this service.
    # These ZFS mounts are materialised from the runtime mount table rather than
    # fstab, so systemd orders against them but will not treat them as hard
    # requirements. Ordering alone does NOT stop the unit starting unmounted.
    #
    # ConditionPathIsMountPoint is what actually enforces it, and it fails in the
    # better direction: an unmet condition SKIPS the unit (recorded as
    # condition-failed, not failed), so the pending job simply waits for the next
    # 5-minute timer instead of being executed against an unwritable path and then
    # swept as "Orphaned" by zimit-progress-monitor. Failing loudly was already
    # guaranteed by the root-owned shadow directory; this makes it not fail at all.
    unitConfig = {
      RequiresMountsFor = [
        workDir
        zimDir
      ];
      ConditionPathIsMountPoint = [
        workDir
        zimDir
      ];
    };

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
      Nice = 15;
      ReadWritePaths = [
        jobQueueDir
        zimDir
        workDir
      ];

      # Note: PrivateTmp disabled - conflicts with podman storage paths.
      # NoNewPrivileges disabled - required for podman user namespace mapping.
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
      # PrivateTmp disabled - podman needs real /tmp for storage paths
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
    # zimDir is SHARED with johnw, who runs git-annex over /tank/Archives.
    # Declared 0775 zimit:johnw rather than 0755 zimit:zimit, and the group-write
    # bit is load-bearing: annexing a ZIM replaces the file with a symlink into
    # .git/annex/objects, which needs write permission on THIS directory. At
    # 0755 zimit:zimit johnw gets only other r-x and `git annex add` fails.
    #
    # This previously declared 0755 zimit:zimit while the live directory was
    # 0775 zimit:johnw — a hand-applied fix the declaration would silently revert
    # on any switch where tmpfiles re-applied ownership. Matching them removes the
    # trap instead of relying on it never firing.
    "d ${zimDir} 0775 zimit johnw -"
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
    # Pulled in by nginx (runs at boot once nginx is up) rather than by
    # multi-user.target, so a slow ZIM scan over the USB tank can never gate
    # multi-user.target. nginx.preStart seeds an empty map, so nginx serves fine
    # before this finishes. RCA: docs/BOOT_SLOWNESS_RCA_2026-06-24.md.
    wantedBy = [ "nginx.service" ];

    path = with pkgs; [
      zim-tools
      coreutils
      gnused
      gnugrep
    ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe kiwixUrlMapGenerator;
      # No ExecStartPost reload here. It fired on EVERY successful run,
      # including the ~251 no-op runs/day driven by zimit-job-runner's
      # 5-minute poll -- 252 nginx reloads on 2026-08-02. The generator now
      # issues the reload itself, only when it actually rewrites the map.
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
    # Hand finished ZIM files to johnw so git-annex can manage them.
    #
    # THE OWNERSHIP CONTRACT for /tank/Archives, in one place, because getting it
    # wrong has broken things in BOTH directions already:
    #
    #   /tank/Archives/.git      johnw:johnw   — git-annex repo metadata, objects
    #                                            and its sqlite databases. zimit has
    #                                            no business here and cannot reach it
    #                                            anyway: .git is absent from the
    #                                            runner's ReadWritePaths.
    #   /tank/Archives/ZIM       zimit:johnw   — the handoff point. zimit owns the
    #                            0775            DIRECTORY so it can mv crawls in;
    #                                            johnw needs group write to replace
    #                                            files with annex symlinks.
    #   ZIM/*.zim (real files)   johnw:zimit   — chowned by the step below, so
    #                            0644            git-annex can take ownership of them.
    #   ZIM/*.zim (symlinks)     untouched     — already annexed; do not chown.
    #   /tank/Archives/work      zimit:zimit   — zimit's private scratch.
    #
    # DO NOT `chown -R` this tree to a single user. Making it all johnw breaks the
    # crawler (zimit loses write on ZIM and cannot land finished archives); making
    # it all zimit breaks git-annex, because chmod requires OWNERSHIP and git-annex
    # freezes/thaws both its objects and its sqlite databases — a non-owner gets
    # EPERM, which surfaces as "setFileMode: permission denied" on fsck and
    # "SQLite3 returned ErrorReadOnly" on sync. Both have happened.
    #
    # WHY: /tank/Archives is a git-annex repository that johnw operates, and
    # git-annex must chmod() its objects to freeze/thaw them. chmod requires
    # OWNERSHIP -- group write is irrelevant, and the kernel returns EPERM
    # ("Operation not permitted", not EACCES) to a non-owner. The runner writes
    # finished ZIMs as `zimit` (see the `mv "$zim" "$ZIM_DIR/"` above), so without
    # this step every new archive arrives in a form johnw cannot annex:
    # `git annex add` on a zimit-owned file fails, verified 2026-08-20 in a
    # throwaway repo (rc=1 for a zimit-owned file, rc=0 for a johnw-owned one).
    #
    # Group stays `zimit` and mode 644 so kiwix-serve -- which runs as zimit --
    # can still read them; confirmed a johnw:zimit 644 file is readable by zimit
    # while 640 is not, so the group bit is doing real work here.
    #
    # Symlinks are skipped: once johnw has run `git annex add`, the entry in ZIM/
    # becomes a symlink into .git/annex/objects and must not be touched.
    #
    # Runs on every runner invocation, including the 5-minute no-op polls. That is
    # deliberate and cheap -- the loop is a glob over one directory and skips files
    # already owned by johnw, so it self-heals a missed handoff rather than only
    # working on the one run that produced a file.
    "+${pkgs.writeShellScript "zimit-zim-handoff" ''
      shopt -s nullglob
      for f in ${zimDir}/*.zim; do
        [ -f "$f" ] || continue
        [ -L "$f" ] && continue
        [ "$(${pkgs.coreutils}/bin/stat -c '%U' "$f")" = "johnw" ] && continue
        ${pkgs.coreutils}/bin/chown johnw:zimit "$f"
        ${pkgs.coreutils}/bin/chmod 644 "$f"
      done
    ''}"
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
  # These were originally blocked because NixOS concatenated all rule files
  # into one, causing duplicate 'groups' keys, which needed the alerting module
  # restructured. That blocker is gone: rules now live in per-service files
  # under modules/monitoring/alerts/, and as of 2026-07-27 zimit.yaml already
  # ships two of the three sketched here:
  # - ZimitJobsFailed: Alert when failed jobs exist            (DONE)
  # - ZimitJobsStuck: Alert when jobs pending > 6h             (DONE, at > 24h)
  # - ZimitArchiveStorageLarge: Alert when storage > 100GB     (still missing)
}
