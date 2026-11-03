# --------------------------------------------------------------------- base ---

FROM golang:1.24 AS base

ARG APP_VERSION=latest

ENV GOOS=linux
ENV GOARCH=amd64
ENV CGO_ENABLED=0

RUN mkdir -p /opt/app/dist
WORKDIR /opt/app

RUN git clone https://github.com/cruxstack/cognito-hooks-go.git .
RUN if [ "$APP_VERSION" != "latest" ] ; then git checkout $APP_VERSION ; fi
RUN go mod download
RUN go build -o dist/bootstrap ./cmd/postconfirmation

# the policy is optional; without one, every native user's password is scrambled
ARG SERVICE_OPA_POLICY_ENCODED=""

RUN if [ -n "$SERVICE_OPA_POLICY_ENCODED" ] ; then echo "$SERVICE_OPA_POLICY_ENCODED" | base64 -d > dist/policy.rego ; fi

# ------------------------------------------------------------------ package ---

FROM alpine:latest AS package

COPY --from=base /opt/app/dist /opt/app/dist

RUN apk add zip \
    && cd /opt/app/dist \
    && zip -r /tmp/package.zip .
