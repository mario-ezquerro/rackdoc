FROM python:3.12-slim

WORKDIR /app

# Instalar ping del sistema para chequeos ICMP en contenedores sin privilegios extra
RUN apt-get update && apt-get install -y --no-install-recommends \
    iputils-ping \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY ./app ./app

RUN mkdir -p /app/data

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
