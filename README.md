The objective of implementing this docker compose stack is to setup monitoring of docker containers running on your host machine. 

Container and Host metrics are captured by cAdvisor and node-exporter services respectively. 

The metrics are then scraped by prometheus and compared against the pre-defined alert rules.

Prometheus then sends the alerts to alert-manager service which sends us notifications on a discord channel of our choice. 

## Local setup for monitoring stack

* Clone the prometheus-grafana-alerts repositrory.

* Now, configure the correct discord webhook url path in the docker-compose.yml file. In order to get the webhook url, follow the below steps.    

    1) Click on **Edit Channel**

        ![settings_button](/images/image-1.png) 

    2) Click on **Integrations -> Webhooks**

        ![Integrations_button](/images/image-2.png)

    3) Click on **New Webhook** if you don't have one and copy the webhook URL, or click on **Copy Webhook URL** if already you have a webhook.

        ![Webhook_url](/images/image-3.png) 

    4) Paste that URL, enclosed in double-quotes (""), in the **DISCORD_WEBHOOK** environment variable in the **alertmanager-discord** service inside the docker-compose.yml file

        ![alertmanager-discord service](/images/image-4.png)

* Next, execute the following command to implement the stack.\
    ```docker compose up -d --build```

* Once the stack is up and running, you can access prometheus service on **http://localhost:9090/** and grafana visualization portal on **http://localhost:3000/**

* On the grafana portal, the default ID and Password is **admin**. Once you enter those defaults, you'll be required to create a new password of your preference. Once that's done you'll enter the grafana landing page. The implemented dashboards can be accessed by clicking on **Dashboards** in the side menu

    ![grafana_sidemenu](/images/image.png)