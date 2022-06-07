FROM debian:11 as builder

LABEL maintainer="shiipou <shiishii@nocturlab.fr>"

ENV GITLY_OAUTH_CLIENT_ID ${GITLY_OAUTH_CLIENT_ID}
ENV GITLY_OAUTH_SECRET ${GITLY_OAUTH_SECRET}

ENV V_HOME /opt/v
ENV GITLY_HOME /opt/gitly

WORKDIR ${V_HOME}

ENV PATH ${PATH}:/opt/vlang

RUN mkdir -p ${V_HOME}

RUN apt-get update \
 && apt-get install -y \
  git make upx gcc \
  musl-dev \
  libssl-dev libsqlite3-dev \
  sassc

RUN git clone https://github.com/vlang/v ${V_HOME} \
 && make \
 && ${V_HOME}/v symlink \
 && v version

RUN v install markdown

WORKDIR ${GITLY_HOME}

COPY . .
RUN sassc ${GITLY_HOME}/static/css/gitly.scss > ${GITLY_HOME}/static/css/gitly.css \
 && v .

FROM scratch

ENV GITLY_HOME /opt/gitly

WORKDIR ${GITLY_HOME}

COPY --from=builder /opt/gitly/gitly .

EXPOSE 8080

CMD ["${GITLY_HOME}/gitly"]

