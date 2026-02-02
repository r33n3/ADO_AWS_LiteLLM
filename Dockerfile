# LiteLLM Proxy Dockerfile
# Uses the official LiteLLM image as base

FROM ghcr.io/berriai/litellm:main-latest

# Set working directory
WORKDIR /app

# Copy configuration file
COPY config.yaml /app/config.yaml

# Expose the default LiteLLM port
EXPOSE 4000

# Health check - use Python to check health endpoint (no external tools needed)
# Extended start-period to allow for database migrations and model initialization
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=5 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:4000/health/liveliness', timeout=5)" || exit 1

# Run LiteLLM proxy with config
CMD ["--config", "/app/config.yaml", "--host", "0.0.0.0", "--port", "4000"]
