# syntax=docker/dockerfile:1

# --- Étape 1 : build Astro statique -----------------------------------
FROM node:20-alpine AS build
WORKDIR /app

COPY package*.json ./
RUN npm ci

COPY . .
RUN npm run build

# --- Étape 2 : image finale, nginx sert dist/ -------------------------
FROM nginx:1.27-alpine AS runtime
COPY deploy/nginx/portfolio.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1

CMD ["nginx", "-g", "daemon off;"]
