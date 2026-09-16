from formapp import create_app

app = create_app()

if __name__ == "__main__":
    host = app.config.get("FORM_HOST", "127.0.0.1")
    port = int(app.config.get("FORM_PORT", 5099))
    app.run(host=host, port=port, debug=False)
