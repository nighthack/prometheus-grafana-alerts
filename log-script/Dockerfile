FROM alpine:latest

RUN apk add --no-cache bash curl docker-cli

COPY logs.sh /logs.sh
RUN chmod +x /logs.sh

CMD ["/logs.sh"]