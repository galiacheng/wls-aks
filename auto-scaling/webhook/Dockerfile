FROM store/oracle/serverjre:8

COPY apps/webhook /bin/webhook
RUN chmod +x /bin/webhook

COPY webhooks/hooks.json /etc/webhook/

COPY scripts/scaleUpAction.sh /var/scripts/

COPY scripts/scaleDownAction.sh /var/scripts/

COPY scripts/scalingAction.sh /var/scripts/

CMD ["-verbose", "-hooks=/etc/webhook/hooks.json", "-hotreload"]

ENTRYPOINT ["/bin/webhook"]