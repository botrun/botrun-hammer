FROM python:3.13-alpine

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

COPY requirements.txt .

# grpcio 在 alpine 沒有 wheel，要從原始碼編；用 virtual package 裝完拆掉
RUN apk add --no-cache --virtual .build-deps gcc g++ musl-dev linux-headers python3-dev && \
    pip install --upgrade pip && \
    pip install -r requirements.txt && \
    apk del .build-deps

COPY main.py .

ENV PORT=8080
EXPOSE 8080

CMD exec gunicorn --bind 0.0.0.0:$PORT --workers 1 --threads 4 --timeout 30 main:app
