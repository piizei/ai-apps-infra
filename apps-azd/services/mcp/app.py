import http.server
import os

PORT = int(os.getenv("PORT", "5003"))
SERVICE_NAME = os.getenv("SERVICE_NAME", "service")
SERVICE_MESSAGE = os.getenv("SERVICE_MESSAGE", f"{SERVICE_NAME} online")


class RequestHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        body = (
            f'{{"service":"{SERVICE_NAME}","message":"{SERVICE_MESSAGE}"}}'.encode("utf-8")
        )
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:  # noqa: A003 - signature from BaseHTTPRequestHandler
        return


if __name__ == "__main__":
    http.server.ThreadingHTTPServer(("", PORT), RequestHandler).serve_forever()
