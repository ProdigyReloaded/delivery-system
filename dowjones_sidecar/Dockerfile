FROM python:3.12-slim

WORKDIR /app

# The quote library pulls curl_cffi as its HTTP client. Ship a slim
# base image; no compiled deps required for our pinned versions.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
