FROM alpine:3.15  AS jbig2enc

WORKDIR /usr/src/jbig2enc

RUN apk add --update build-base automake autoconf libtool leptonica-dev zlib-dev git ca-certificates

RUN git clone https://github.com/agl/jbig2enc .
RUN ./autogen.sh
RUN ./configure && make

# ==========================

FROM alpine:3.15 AS builder

ARG ICC_PROFILES_URL=http://archive.ubuntu.com/ubuntu/pool/main/i/icc-profiles-free/icc-profiles-free_2.0.1+dfsg.orig.tar.bz2

WORKDIR /app

COPY requirements.txt ./

# Python dependencies
RUN apk add --update --no-cache \
    build-base libpq-dev qpdf-dev python3-dev libffi-dev openblas-dev libxslt-dev \
    py3-scikit-learn py3-numpy py3-scipy py3-pikepdf py3-cryptography py3-pillow py3-pip py3-wheel

RUN python3 -m pip install --upgrade pip && \
    python3 -m pip install --no-cache-dir --prefix /install -r ./requirements.txt

RUN find /install -type d -name '__pycache__' -exec rm -rf {} +

RUN wget -q -O /tmp/icc.tar.bz2 $ICC_PROFILES_URL && \
    tar xf /tmp/icc.tar.bz2 -C /install

# ==========================
FROM alpine:3.15

# Binary dependencies
RUN apk add --update --no-cache \
    # Basic dependencies
    curl bash gnupg imagemagick gettext tzdata sudo supervisor \
    py3-scikit-learn py3-numpy py3-scipy py3-pikepdf py3-cryptography py3-pillow \
    # fonts for text file thumbnail generation
    ttf-liberation \
    # for Numpy
    openblas libxslt \
    # thumbnail size reduction
    optipng libxml2 pngquant unpaper zlib ghostscript \
    # Mime type detection
    file shared-mime-info libmagic \
    # OCRmyPDF dependencies
    leptonica qpdf tesseract-ocr

# copy deps
COPY --from=builder /install/bin /usr/local/bin
COPY --from=builder /install/lib /usr/lib
COPY --from=builder /install/icc-profiles-free*/* /usr/share/color/icc/

# copy jbig2enc
COPY --from=jbig2enc /usr/src/jbig2enc/src/.libs/libjbig2enc* /usr/local/lib/
COPY --from=jbig2enc /usr/src/jbig2enc/src/jbig2 /usr/local/bin/
COPY --from=jbig2enc /usr/src/jbig2enc/src/*.h /usr/local/include/

WORKDIR /app

# setup docker-specific things
COPY docker/ ./src/docker/

RUN cd src/docker \
    && cp imagemagick-policy.xml /etc/ImageMagick-7/policy.xml \
    && mkdir /var/log/supervisord /var/run/supervisord \
    && mkdir -p /config /data/media /data/consume \
    && cp supervisord.conf /etc/supervisord.conf \
    && cp docker-entrypoint.sh /sbin/docker-entrypoint.sh \
    && cp docker-prepare.sh /sbin/docker-prepare.sh \
    && chmod 755 /sbin/docker-entrypoint.sh \
    && chmod +x install_management_commands.sh \
    && ./install_management_commands.sh \
    && cd .. \
    && rm docker -rf \
    && addgroup -g 1000 -S paperless \
    && adduser -u 1000 -S -G paperless -h /app paperless \
    && chown -R paperless:paperless /app /config /data

WORKDIR /app/src

# copy app
COPY --chown=paperless:paperless src/ ./
COPY --chown=paperless:paperless gunicorn.conf.py ../

ENV PAPERLESS_DATA_DIR=/config \
    PAPERLESS_MEDIA_ROOT=/data/media \
    PAPERLESS_CONSUMPTION_DIR=/data/consume

RUN sudo -u paperless python3 manage.py collectstatic --clear --no-input && \
    sudo -u paperless python3 manage.py compilemessages

VOLUME ["/config", "/data"]
ENTRYPOINT ["/sbin/docker-entrypoint.sh"]
EXPOSE 8000
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]

LABEL maintainer="Jonas Winkler <dev@jpwinkler.de>"
