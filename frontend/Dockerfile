FROM nginx:alpine

RUN sed -i 's/application\/javascript\([[:space:]]\+\)js;/application\/javascript\1js mjs;/' /etc/nginx/mime.types

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY build/web /usr/share/nginx/html

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
