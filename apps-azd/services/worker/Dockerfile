FROM python:3.12-alpine
WORKDIR /app
COPY app.py ./app.py
ENV PORT=8080
ENV SERVICE_NAME=worker
ENV SERVICE_MESSAGE="worker container ready"
EXPOSE 8080
CMD ["python", "app.py"]
