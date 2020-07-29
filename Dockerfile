FROM alpine:3.12

LABEL maintainer="shiipou <shiishii@nocturlab.fr>"

ENV GITLY_OAUTH_CLIENT_ID ${GITLY_OAUTH_CLIENT_ID}
ENV GITLY_OAUTH_SECRET ${GITLY_OAUTH_SECRET}

ENV V_HOME /opt/v
ENV GITLY_HOME /opt/gitly

WORKDIR ${V_HOME}

ENV PATH ${PATH}:/opt/vlang

RUN mkdir -p ${V_HOME}

RUN apk --no-cache add \
  git make upx gcc \
  musl-dev \
  openssl-dev sqlite-dev \
  libx11-dev glfw-dev freetype-dev \
  libsqlite3-dev \
  sassc

RUN apk --no-cache add --virtual sdl2deps sdl2-dev sdl2_ttf-dev sdl2_mixer-dev sdl2_image-dev

RUN git clone https://github.com/vlang/v ${V_HOME} \
 && make \
 && ${V_HOME}/v symlink \
 && v version

RUN v install markdown

WORKDIR ${GITLY_HOME}

COPY . .
RUN sassc ${GITLY_HOME}/static/css/gitly.scss > ${GITLY_HOME}/static/css/gitly.css \
 && v .

EXPOSE 8080

CMD ${GITLY_HOME}/gitly
