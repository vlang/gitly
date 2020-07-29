FROM thevlang/vlang:alpine

LABEL maintainer="shiipou <shiishii@nocturlab.fr>"

ENV GITLY_OAUTH_CLIENT_ID ${GITLY_OAUTH_CLIENT_ID}
ENV GITLY_OAUTH_SECRET ${GITLY_OAUTH_SECRET}

ENV GITLY_HOME /opt/gitly

WORKDIR ${GITLY_HOME}

RUN v install markdown

COPY . .
RUN sassc ${GITLY_HOME}/static/css/gitly.scss > ${GITLY_HOME}/static/css/gitly.css \
 && v .

EXPOSE 8080

CMD ${GITLY_HOME}/gitly
