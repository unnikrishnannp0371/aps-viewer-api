FROM ruby:4.0-slim AS builder

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      build-essential \
      libpq-dev \
      git \
      curl \
      pkg-config \
      libyaml-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY Gemfile Gemfile.lock ./

RUN bundle config set --local deployment 'true' && \
    bundle config set --local without 'development test' && \
    bundle install --jobs 4 --retry 3

COPY . .

FROM ruby:4.0-slim AS production

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      libpq5 \
      curl \
      tzdata \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --system rails && \
    useradd --system --gid rails --home /app --shell /bin/bash rails

WORKDIR /app

COPY --from=builder /usr/local/bundle /usr/local/bundle
COPY --from=builder --chown=rails:rails /app /app

RUN mkdir -p tmp/pids tmp/cache log && \
    chown -R rails:rails tmp log

USER rails
EXPOSE 3000

CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]