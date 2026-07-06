FROM python:3.13-alpine

WORKDIR /app
COPY exporter.py /app/exporter.py

EXPOSE 9101

ENTRYPOINT ["python", "/app/exporter.py"]
