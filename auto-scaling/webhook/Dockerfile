FROM store/oracle/serverjre:8

COPY apps/webhook /bin/webhook
RUN chmod +x /bin/webhook

COPY webhooks/hooks.json /etc/webhook/
RUN chmod +x /etc/webhook/hooks.json

COPY scripts/scaleUpAction.sh /var/scripts/
RUN chmod +x /var/scripts/scaleUpAction.sh

COPY scripts/scaleDownAction.sh /var/scripts/
RUN chmod +x /var/scripts/scaleUpAction.sh

COPY scripts/scalingAction.sh /var/scripts/
RUN chmod +x /var/scripts/scalingAction.sh

CMD ["-verbose", "-hooks=/etc/webhook/hooks.json", "-hotreload"]

ENTRYPOINT ["/bin/webhook"]
