# --------------------------------------------------------------------- base ---

FROM golang:1.24 AS base

ARG APP_VERSION=latest

ENV GOOS=linux
ENV GOARCH=amd64
ENV CGO_ENABLED=0

RUN mkdir -p /opt/app
WORKDIR /opt/app

RUN git clone https://github.com/cruxstack/cognito-hooks-go.git .
RUN if [ "$APP_VERSION" != "latest" ] ; then git checkout $APP_VERSION ; fi
RUN go mod download
RUN go build -o bootstrap ./cmd/presignup

ARG SERVICE_OPA_POLICY_ENCODED=cGFja2FnZSBjb2duaXRvX2hvb2tfcHJlc2lnbnVwCgppbXBvcnQgcmVnby52MQoKcmVzdWx0IDo9IHsKICJhY3Rpb24iOiAiYWxsb3ciLAogInJlc3BvbnNlIjoge30KfQo=

RUN echo "$SERVICE_OPA_POLICY_ENCODED" | base64 -d > /opt/app/policy.rego

# ------------------------------------------------------------------ package ---

FROM alpine:latest AS package

COPY --from=base /opt/app/bootstrap /opt/app/dist/bootstrap
COPY --from=base /opt/app/policy.rego /opt/app/dist/policy.rego

RUN apk add zip \
    && cd /opt/app/dist \
    && zip -r /tmp/package.zip .
