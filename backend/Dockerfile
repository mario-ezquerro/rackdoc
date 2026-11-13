FROM python:3.12-slim

WORKDIR /app

# Instalar ping, cliente SSH y sshpass para chequeos ICMP y aprovisionamiento Ansible sin privilegios extra
RUN apt-get update && apt-get install -y --no-install-recommends \
    iputils-ping \
    openssh-client \
    sshpass \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
    && ansible-galaxy collection install ansible.windows community.windows

COPY ./app ./app
COPY alembic.ini .
COPY ./alembic ./alembic
COPY ./tools ./tools
COPY pytest.ini .
COPY ./tests ./tests

RUN mkdir -p /app/data

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
