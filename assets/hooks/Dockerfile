# Builds the hooks function (cruxstack/cognito-hooks-go) for AWS Lambda
# (provided.al2023) and packages it with the PreSignUp and PostConfirmation
# policies.

# --------------------------------------------------------------------- base ---

FROM golang:1.27 AS base

# a git tag or other ref of cognito-hooks-go; "latest" builds the default
# branch, which can include breaking changes
ARG APP_VERSION=v1.0.0
ARG GOARCH=arm64

ENV GOOS=linux
ENV GOARCH=${GOARCH}
ENV CGO_ENABLED=0

WORKDIR /opt/app

RUN git clone https://github.com/cruxstack/cognito-hooks-go.git . \
    && if [ "$APP_VERSION" != "latest" ]; then git checkout "$APP_VERSION"; fi
RUN go mod download
RUN go build -trimpath -tags lambda.norpc -ldflags "-s -w -X main.version=${APP_VERSION}" -o dist/bootstrap .

# the policies are passed base64-encoded so any content survives a build arg;
# a hook without a policy gets no file
ARG PRESIGNUP_POLICY_ENCODED=""
ARG POSTCONFIRMATION_POLICY_ENCODED=""
RUN if [ -n "$PRESIGNUP_POLICY_ENCODED" ]; then echo "$PRESIGNUP_POLICY_ENCODED" | base64 -d > dist/presignup.rego; fi \
    && if [ -n "$POSTCONFIRMATION_POLICY_ENCODED" ]; then echo "$POSTCONFIRMATION_POLICY_ENCODED" | base64 -d > dist/postconfirmation.rego; fi

# ------------------------------------------------------------------ package ---

FROM alpine:3 AS package

COPY --from=base /opt/app/dist /opt/app/dist

RUN apk add --no-cache zip \
    && cd /opt/app/dist \
    && zip -r /tmp/package.zip .
