# OLD: FROM python:latest
FROM python:3.12-slim

WORKDIR /app

# OLD: COPY . .
COPY app/ .

# OLD: RUN pip install -r app/requirements.txt
RUN pip install -r requirements.txt

# OLD: ENV DB_PASSWORD=SuperSecret123!

EXPOSE 8080

# OLD: CMD ["python", "app/app.py"]
CMD ["python", "app.py"]
