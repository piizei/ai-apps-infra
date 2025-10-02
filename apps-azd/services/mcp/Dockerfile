FROM python:3.12-alpine
WORKDIR /app
COPY app.py ./app.py
ENV PORT=5003
ENV SERVICE_NAME=mcp
ENV SERVICE_MESSAGE="mcp container ready"
EXPOSE 5003
CMD ["python", "app.py"]
