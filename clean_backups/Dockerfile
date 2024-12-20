FROM amazon/aws-cli:latest

COPY clean_backups.sh /bin/clean_backups.sh
RUN chmod +x /bin/clean_backups.sh
COPY config /root/.aws/config
COPY credentials /root/.aws/credentials

ENTRYPOINT ["/bin/clean_backups.sh"]
