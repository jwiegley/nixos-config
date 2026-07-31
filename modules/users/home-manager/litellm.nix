{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:

{
  # Deploy harmony_filter.py from this repo's scripts/ to /etc/litellm. The
  # source is copied into the Nix store at build time, so /etc/nixos is not
  # read at runtime.
  environment.etc."litellm/harmony_filter.py" = {
    source = ../../../scripts/harmony_filter.py;
    mode = "0644";
  };

  # Keep selected slow streams alive and align OpenAI's transport with their request timeout.
  environment.etc."litellm/sitecustomize.py" = {
    mode = "0644";
    text = ''
      import asyncio
      import httpx

      from litellm.llms.openai.openai import OpenAIChatCompletion as _OpenAIChatCompletion
      from litellm.proxy import common_request_processing as _request_processing
      from starlette.responses import StreamingResponse

      _original_create_response = _request_processing.create_response
      _HEADER = "x-litellm-first-token-heartbeat"


      async def _create_response_with_first_token_heartbeat(
          generator,
          media_type,
          headers,
          default_status_code=200,
          request=None,
      ):
          raw_interval = request.headers.get(_HEADER) if request is not None else None
          if raw_interval is None:
              return await _original_create_response(
                  generator,
                  media_type,
                  headers,
                  default_status_code,
                  request,
              )

          interval = min(60.0, max(1.0, float(raw_interval)))
          if asyncio.iscoroutine(generator):
              generator = await generator

          async def stream_with_heartbeat():
              pending_chunk = None
              try:
                  while True:
                      pending_chunk = asyncio.ensure_future(generator.__anext__())
                      while not pending_chunk.done():
                          await asyncio.wait({pending_chunk}, timeout=interval)
                          if not pending_chunk.done():
                              yield ": keepalive\n\n"
                      try:
                          chunk = pending_chunk.result()
                      except StopAsyncIteration:
                          return
                      pending_chunk = None
                      yield chunk
              finally:
                  if pending_chunk is not None and not pending_chunk.done():
                      pending_chunk.cancel()
                  try:
                      await generator.aclose()
                  except BaseException:
                      pass

          return StreamingResponse(
              stream_with_heartbeat(),
              media_type=media_type,
              status_code=default_status_code,
              headers={**headers, "Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
          )


      _original_get_async_http_client = _OpenAIChatCompletion._get_async_http_client


      def _get_async_http_client_with_long_timeout(shared_session=None):
          client = _original_get_async_http_client(shared_session)
          if client is not None:
              client.timeout = httpx.Timeout(7200.0)
          return client


      _OpenAIChatCompletion._get_async_http_client = staticmethod(
          _get_async_http_client_with_long_timeout
      )
      _request_processing.create_response = _create_response_with_first_token_heartbeat
    '';
  };

  # Deploy logging config to suppress INFO-level scheduler logs
  environment.etc."litellm/logging.conf" = {
    source = ../../../files/litellm-logging.conf;
    mode = "0644";
  };

  home-manager.users.litellm =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      # Import the quadlet-nix Home Manager module
      imports = [
        inputs.quadlet-nix.homeManagerModules.quadlet
      ];
      # Home Manager state version
      home.stateVersion = "24.11";

      # Basic home settings
      home.username = "litellm";
      home.homeDirectory = "/var/lib/containers/litellm";

      # Environment for rootless container operation
      home.sessionVariables = {
        PODMAN_USERNS = "keep-id";
      };

      # Ensure home directory structure exists
      home.file.".keep".text = "";

      # Basic packages available in container user environment
      home.packages = with pkgs; [
        podman
        coreutils
        postgresql # For pg_isready health check
      ];

      # Rootless quadlet container configuration
      virtualisation.quadlet.containers.litellm = {
        autoStart = true;

        containerConfig = {
          image = "ghcr.io/berriai/litellm-database:main-stable";
          publishPorts = [ "127.0.0.1:4000:4000/tcp" ];

          # Rootless networking with host loopback access
          networks = [ "slirp4netns:allow_host_loopback=true" ];

          # Environment configuration
          environments = {
            # aiohttp cuts slow first-token streams at 300s despite LiteLLM's configured timeouts.
            DISABLE_AIOHTTP_TRANSPORT = "True";
            POSTGRES_HOST = "127.0.0.1";
            PYTHONPATH = "/app";
            LITELLM_LOG = "WARNING"; # Suppress INFO-level scheduler logs
            LOG_LEVEL = "WARNING"; # Python logging level
          };

          # Secrets via environment file
          environmentFiles = [ "/run/secrets-litellm/litellm-secrets" ];

          # Volume mounts
          volumes = [
            "/etc/litellm/config.yaml:/app/config.yaml:ro"
            "/etc/litellm/harmony_filter.py:/app/harmony_filter.py:ro"
            "/etc/litellm/logging.conf:/app/logging.conf:ro"
            "/etc/litellm/sitecustomize.py:/app/sitecustomize.py:ro"
          ];

          # Container exec command
          exec = "--config /app/config.yaml --log_config /app/logging.conf";
        };

        unitConfig = {
          After = [ "network-online.target" ];

          # Restart rate limiting
          StartLimitIntervalSec = "300";
          StartLimitBurst = "5";
        };

        serviceConfig = {
          # Wait for PostgreSQL to be ready
          ExecStartPre = "${pkgs.bash}/bin/bash -c 'for i in {1..60}; do ${pkgs.postgresql}/bin/pg_isready -h 127.0.0.1 -p 5432 -t 2 && exit 0; ${pkgs.coreutils}/bin/sleep 2; done; exit 1'";

          # Restart policies
          Restart = "always";
          RestartSec = "10s";
          TimeoutStartSec = "900";

          # Suppress INFO/DEBUG journal noise (only store warning and above)
          LogLevelMax = "warning";
        };
      };
    };
}
