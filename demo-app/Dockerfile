FROM python:3.12-slim

WORKDIR /app

# Les dépendances d'abord : cette couche est mise en cache tant que
# requirements.txt ne change pas, ce qui accélère les builds suivants.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

# La version affichée par /health est fixée à la construction de l'image.
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}

# Ne pas exécuter l'application en root dans le conteneur.
RUN useradd --system --no-create-home appuser
USER appuser

EXPOSE 8000
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "app:app"]