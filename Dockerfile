# syntax=docker/dockerfile:1
#
# Dispatch Rules Guard. One Dockerfile, two runnable targets:
#   app  (the default, last stage)  the production web app: `bin/rails db:prepare`, then ONE
#        Puma process (the rate limiter, webhook queue and clock live in process memory;
#        see config/puma.rb and docs/CONFIGURATION.md)
#   test  the Cucumber and minitest suites, with headless Chromium for @javascript scenarios
#
# Configuration comes from the environment (docs/CONFIGURATION.md): SECRET_KEY_BASE (required),
# DISPATCH_API_TOKENS, DISPATCH_WEBHOOK_URL / _SECRET, DISPATCH_RATE_LIMIT, DATABASE_PATH, ...
# Nothing secret is baked into the image.
#
# Debian bookworm (glibc). Gemfile.lock pins precompiled native gems for x86_64-linux and
# aarch64-linux (glibc) and x86_64-linux-musl, so this builds on amd64 and arm64 hosts.

ARG RUBY_VERSION=3.3

# --- base: Ruby and the app's runtime settings, shared by every stage ---
FROM ruby:${RUBY_VERSION}-slim-bookworm AS base
WORKDIR /app
ENV LANG=C.UTF-8 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_JOBS=4

# --- build: compilers for the gems without precompiled binaries (puma, nio4r, bigdecimal, ...) ---
FROM base AS build
RUN apt-get update -qq \
 && apt-get install --no-install-recommends -y build-essential \
 && rm -rf /var/lib/apt/lists/*
COPY Gemfile Gemfile.lock ./

FROM build AS gems-app
ENV BUNDLE_WITHOUT=test
RUN bundle install && rm -rf "${BUNDLE_PATH}"/ruby/*/cache

FROM build AS gems-test
RUN bundle install && rm -rf "${BUNDLE_PATH}"/ruby/*/cache

# --- test: `docker compose run --rm test` (see docker-compose.yml) ---
FROM base AS test
RUN apt-get update -qq \
 && apt-get install --no-install-recommends -y chromium chromium-driver \
 && rm -rf /var/lib/apt/lists/*
COPY --from=gems-test /usr/local/bundle /usr/local/bundle
RUN groupadd --system --gid 1000 app \
 && useradd --system --uid 1000 --gid app --create-home --shell /bin/bash app
COPY . .
RUN mkdir -p storage tmp log reports \
 && chown -R app:app storage tmp log reports
# CI=1: Chromium runs with --no-sandbox, since containers rarely allow its sandbox
# (features/support/capybara.rb, docs/CONFIGURATION.md).
ENV RAILS_ENV=test \
    CI=1 \
    CHROME_BIN=/usr/bin/chromium \
    CHROMEDRIVER_PATH=/usr/bin/chromedriver
USER app:app
CMD ["sh", "-c", "bin/rails db:prepare && bundle exec cucumber"]

# --- app: the production image (default target) ---
FROM base AS app
ENV RAILS_ENV=production \
    BUNDLE_WITHOUT=test \
    PORT=3000
COPY --from=gems-app /usr/local/bundle /usr/local/bundle
RUN groupadd --system --gid 1000 app \
 && useradd --system --uid 1000 --gid app --no-create-home --shell /usr/sbin/nologin app
# The code is owned by root and read-only to the app user; only the database, tmp and log
# directories are writable.
COPY . .
RUN mkdir -p storage tmp log \
 && chown -R app:app storage tmp log
USER app:app
VOLUME ["/app/storage"]
EXPOSE 3000
HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=3 \
  CMD ruby -rnet/http -e 'exit Net::HTTP.get_response(URI("http://127.0.0.1:#{ENV.fetch("PORT", "3000")}/up")).is_a?(Net::HTTPSuccess) ? 0 : 1'
# Creates and seeds the database on first start (the shipped roster), migrates it after.
# `exec` makes Puma PID 1, so `docker stop` reaches it directly.
CMD ["sh", "-c", "bin/rails db:prepare && exec bundle exec puma -C config/puma.rb"]
