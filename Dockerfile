# Playwright base ships Chromium + all system deps (Ubuntu jammy), matching
# playwright 1.60.0 — sidesteps installing browser deps on Amazon Linux.
# ponytail: MS Playwright base + aws-lambda-ric. If image size becomes a problem,
# the upgrade path is playwright-core + @sparticuz/chromium on the AWS base image.
FROM mcr.microsoft.com/playwright:v1.60.0-jammy

ENV HOME=/tmp
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
WORKDIR /var/task

COPY package.json ./
RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake g++ make libcurl4-openssl-dev python3 autoconf automake libtool xz-utils \
    && rm -rf /var/lib/apt/lists/*
RUN npm install --omit=dev && npm install aws-lambda-ric

COPY src/ ./src/
COPY handler.js ./

ENTRYPOINT ["npx", "aws-lambda-ric"]
CMD ["handler.handler"]
