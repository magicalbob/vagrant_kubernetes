FROM amazon/aws-cli:latest

COPY clean_backups.sh /bin/clean_backups.sh
RUN chmod +x /bin/clean_backups.sh

ENTRYPOINT ["/bin/clean_backups.sh"]
