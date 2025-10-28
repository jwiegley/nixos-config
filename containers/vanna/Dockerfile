FROM python:3.11-slim

# Install system dependencies including MS SQL Server ODBC drivers
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        git \
        build-essential \
        freetds-dev \
        freetds-bin \
        tdsodbc \
        unixodbc-dev \
        curl \
        gnupg2 \
    && rm -rf /var/lib/apt/lists/*

# Create working directory
WORKDIR /app

# Clone vanna-flask repository
RUN git clone https://github.com/vanna-ai/vanna-flask.git .

# Remove the git clone's app.py to ensure our custom one is used
RUN rm -f app.py && ls -la

# Copy custom app.py that uses local OpenAI-compatible API
COPY custom-app.py app.py

# Verify the copy worked
RUN ls -la app.py && wc -l app.py && echo "=== Checking for allow_llm_to_see_data parameter ===" && grep -n "allow_llm_to_see_data=True" app.py || echo "ERROR: Parameter not found!"

# Install Python dependencies
# Using FAISS for vector store (simpler, no compatibility issues)
RUN pip install --no-cache-dir -r requirements.txt && \
    pip install --no-cache-dir \
        faiss-cpu \
        sentence-transformers \
        vanna[postgres] \
        vanna[mssql] \
        gevent \
        psycopg2-binary \
        pymssql \
        pyodbc \
        openai

# Create directories for persistent data
RUN mkdir -p /vanna/faiss /vanna/cache

# Expose Flask port
EXPOSE 5000

# Set environment variables
ENV FLASK_APP=app.py
ENV FLASK_ENV=production
ENV PYTHONUNBUFFERED=1

# Run Flask app
CMD ["python", "app.py"]
