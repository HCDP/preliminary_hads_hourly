#SET UP FROM PRODUCTION BASE IMAGE
FROM ghcr.io/hcdp/task-base:latest
LABEL org.opencontainers.image.source="https://github.com/hcdp/preliminary_hads_hourly"
LABEL org.opencontainers.image.description="Image for the Preliminary HADS Hourly Workflow."

# Let APT know that we don't have a terminal.
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    r-base \
    libssl-dev \
    curl \
    libcurl4-openssl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN Rscript -e "install.packages(c('httr2', 'dplyr', 'tibble', 'readr'), repos='https://cloud.r-project.org')"

COPY code/ /workspace/code/
COPY envs/prod.env /workspace/envs/prod.env
COPY containers/task.sh /workspace/task.sh