FROM gliderlabs/alpine:3.1

MAINTAINER Drew Ditthardt <dditthardt@olivinelabs.com>

RUN apk --update add iptables
RUN apk --update add ip6tables
RUN apk --update add luajit
RUN apk --update add docker

RUN ln -s /usr/lib/libluajit-5.1.so.2 /lib/liblua5.1.so.0

ADD lib/ljsyscall /lib/lua

ADD src/init.lua /sbin/init
ADD src/init /lib/lua/init

ENTRYPOINT /sbin/init
EXPOSE 2375
