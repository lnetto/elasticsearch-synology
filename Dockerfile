# Elasticsearch for Synology DSM, whose kernel lacks CONFIG_SECCOMP.
#
# Since 8.0 Elasticsearch always installs a seccomp system call filter and,
# since 9.x, aborts startup when the kernel can't do it. Two classes are
# rebuilt from the matching upstream source:
#   - LinuxNativeAccess: the failed install is logged as a warning instead of
#     thrown.
#   - BootstrapChecks: SystemCallFilterCheck is dropped, otherwise a
#     multi-node cluster (where bootstrap checks are enforced) refuses to start.
# Each patch is guarded by a grep count, so a new upstream version that no
# longer matches fails the build rather than producing a broken image.
#
# Build:  docker build --build-arg ES_VERSION=9.5.5 -t elasticsearch-synology:9.5.5 .

ARG ES_VERSION=9.5.5

FROM docker.elastic.co/elasticsearch/elasticsearch:${ES_VERSION} AS build
ARG ES_VERSION
USER root
WORKDIR /build
RUN set -eux; \
    ES=/usr/share/elasticsearch; JDK=$ES/jdk/bin; \
    RAW=https://raw.githubusercontent.com/elastic/elasticsearch/v${ES_VERSION}; \
    NATIVE=org/elasticsearch/nativeaccess/LinuxNativeAccess.java; \
    CHECKS=org/elasticsearch/bootstrap/BootstrapChecks.java; \
    mkdir -p src/$(dirname $NATIVE) src/$(dirname $CHECKS) native server; \
    curl -fsSL -o src/$NATIVE $RAW/libs/native/src/main/java/$NATIVE; \
    curl -fsSL -o src/$CHECKS $RAW/server/src/main/java/$CHECKS; \
    test "$(grep -c 'public void tryInstallExecSandbox() {' src/$NATIVE)" = 1; \
    sed -i 's|public void tryInstallExecSandbox() {|public void tryInstallExecSandbox() {\n        try {\n            tryInstallExecSandbox0();\n        } catch (UnsupportedOperationException e) {\n            logger.warn("system call filter not installed (patched for kernels without seccomp): " + e.getMessage());\n        }\n    }\n\n    private void tryInstallExecSandbox0() {|' src/$NATIVE; \
    test "$(grep -c 'checks.add(new SystemCallFilterCheck());' src/$CHECKS)" = 1; \
    sed -i 's|checks.add(new SystemCallFilterCheck());|// SystemCallFilterCheck removed: kernel has no seccomp (Synology DSM)|' src/$CHECKS; \
    $JDK/javac --release 21 -nowarn -d native -cp "$ES/lib/*" src/$NATIVE; \
    $JDK/javac --release 21 -nowarn -d server -cp "$ES/lib/*" src/$CHECKS; \
    cp $ES/lib/elasticsearch-native-${ES_VERSION}.jar $ES/lib/elasticsearch-${ES_VERSION}.jar .; \
    $JDK/jar uf elasticsearch-native-${ES_VERSION}.jar -C native .; \
    $JDK/jar uf elasticsearch-${ES_VERSION}.jar -C server .

FROM docker.elastic.co/elasticsearch/elasticsearch:${ES_VERSION}
ARG ES_VERSION
COPY --from=build /build/elasticsearch-native-${ES_VERSION}.jar /build/elasticsearch-${ES_VERSION}.jar /usr/share/elasticsearch/lib/
