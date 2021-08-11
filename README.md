# Change Data Capture
This repo is meant as a baseline for learning and demoing change data capture. I've tried to make it as agnostic as possible with specific sections for specific CDC tools. 

Using the [menagerie example database](https://dev.mysql.com/doc/index-other.html) loaded into Cloud SQL.

Followed the MySQL configuration for Datastream [here](https://cloud.google.com/datastream/docs/configure-your-source-mysql-database#cloudsqlformysql)

Table of Contents
=================

* [Change Data Capture](#change-data-capture)
* [Infra Set Up via Terraform](#infra-set-up-via-terraform)
  * [Add Some Data](#add-some-data)
* [Datastream](#datastream)
  * [Create Stream](#create-stream)
* [Changing Data](#changing-data)
* [Random Bits](#random-bits)
  * [Cleanup](#cleanup)
  * [SQL Auth Proxy](#sql-auth-proxy)
  * [Some notes on SSL for Cloud SQL](#some-notes-on-ssl-for-cloud-sql)

Created by [gh-md-toc](https://github.com/ekalinin/github-markdown-toc.go)



# Infra Set Up via Terraform

**Note** You will need a mysql client installed.

**Note**: Because we'll be using local files, we need to connect directly using the mysql client, so the [Auth Proxy](https://cloud.google.com/sql/docs/mysql/quickstart-proxy-test#macos-64-bit) will be needed.


```bash
export PROJECT_ID=MY_SWEET_PROJECT

```

```bash
export TF_VAR_project=$PROJECT_ID

terraform init
terraform plan
terraform apply

export INSTANCE=$(terraform output -raw master_sql_name)
export ANIMAL_PASSWD=$(terraform output -raw animal_user_passwd)
export TARGET_BKT=$(terraform output -raw target_bucket)

export REGION=$(terraform output -raw region)

export CONNECTION_NAME=$PROJECT_ID:$REGION:$INSTANCE

```

## Add Some Data
Open a new shell (might need to copy over the `$CONNECTION_NAME` value) and dive into the directory with the proxy:
```bash
./cloud_sql_proxy -instances=$CONNECTION_NAME=tcp:3306
```

Now connect to the sql instance. Note that the password is in the `$ANIMAL_PASSWD` value
```bash
mysql -u animal -p --host 127.0.0.1 --port 3306 --local-infile=1
```
After the files below have been loaded, this command can be used to connect:

```bash
gcloud sql connect $INSTANCE -u animal
```

Now set up the DB and import records
```sql

USE menagerie;
SOURCE ./menagerie-db/cr_pet_tbl.sql
LOAD DATA LOCAL INFILE './menagerie-db/pet.txt' INTO TABLE pet;
SOURCE ./menagerie-db/ins_puff_rec.sql
SOURCE ./menagerie-db/cr_event_tbl.sql
LOAD DATA LOCAL INFILE './menagerie-db/event.txt' INTO TABLE event;
```

This might work better?

```bash

mysql -u animal -p --host 127.0.0.1 --port 3306 menagerie < ./menagerie-db/cr_pet_tbl.sql
mysql -u animal -p --host 127.0.0.1 --port 3306 menagerie < ./menagerie-db/load_pet_tbl.sql
mysqlimport -u animal -p --host 127.0.0.1 --port 3306 --local menagerie ./menagerie-db/pet.txt

mysql -u animal -p --host 127.0.0.1 --port 3306 menagerie < ./menagerie-db/ins_puff_rec.sql
mysql -u animal -p --host 127.0.0.1 --port 3306 menagerie < ./menagerie-db/cr_event_tbl.sql
mysqlimport -u animal -p --host 127.0.0.1 --port 3306 --local menagerie ./menagerie-db/event.txt
```


# Datastream
Grant some permissions to the datastream user
```sql

CREATE USER 'datastream'@'%' IDENTIFIED BY '$OME_SWEET_word! here';
GRANT REPLICATION SLAVE, SELECT, RELOAD, REPLICATION CLIENT, LOCK TABLES, EXECUTE ON *.* TO 'datastream'@'%';
FLUSH PRIVILEGES;
```

Get the IP address of the instance. 
```bash
gcloud sql instances describe $INSTANCE --format="value(ipAddresses[0].ipAddress)"
```

Get the name of the bucket
```bash
echo $TARGET_BKT
```


## Create Stream
After the DB is set up, we create the stream via the UI. Use Cloud Storage and **`json`** output. 


## Add Dataflow Job
Datastream only gets it halfway. We need to use a dataflow template to get the data from the Storage bucket into BigQuery. Synthenized from [here](https://cloud.google.com/dataflow/docs/guides/templates/provided-streaming#datastream-to-bigquery).

The `events.schema.json` and `pets.schema.json` files contain the BQ table schemas. 


First, create the notification on the bucket and grant the dataflow user access to the bucket, then kick off the job.
```bash
gsutil notification create -t menagerie-changes -f json gs://$TARGET_BKT

export PRJ_NUM=$( gcloud projects describe $PROJECT_ID --format="value(projectNumber)")

gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:service-$PRJ_NUM@dataflow-service-producer-prod.iam.gserviceaccount.com" --role='roles/storage.objectAdmin'

# Technically this might be more secure due to least privilege
# gsutil iam ch serviceAccount:service-$PRJ_NUM@dataflow-service-producer-prod.iam.gserviceaccount.com:roles/storage.objectAdmin gs://$TARGET_BKT


gcloud beta dataflow flex-template run menagerie-changes-pipeline-events \
    --project=$PROJECT_ID \
    --region=$REGION \
    --enable-streaming-engine \
    --template-file-gcs-location=gs://dataflow-templates/latest/flex/Cloud_Datastream_to_BigQuery \
    --parameters \
inputFilePattern=$TARGET_BKT,\
inputFileFormat=json,\
gcsPubSubSubscription=projects/$PROJECT_ID/subscriptions/menagerie-changes,\
outputStagingDatasetTemplate=menagerie_reporting,\
outputDatasetTemplate=menagerie_reporting,\
deadLetterQueueDirectory=$TARGET_BKT

```



# Changing Data
Some example SQL cmds to generate some data. Probably could be improved to do some randomness.

```sql

INSERT INTO pet VALUES ('Bonnie','Travis','cat','f','2017-04-14',NULL);
INSERT INTO pet VALUES ('Cyde','Travis','cat','m','2017-04-14',NULL);


INSERT INTO event VALUES ('Bowser', '2021-08-02', 'feeding', 'Fed him mario treats')
INSERT INTO event VALUES ('Bowser', '2021-08-03', 'feeding', 'Fed him mario treats')
INSERT INTO event VALUES ('Bowser', '2021-08-03', 'belly scratches', 'Such a good boi')
INSERT INTO event VALUES ('Bowser', '2021-08-04', 'belly scratches', 'Such a good boi')
INSERT INTO event VALUES ('Bowser', '2021-08-05', 'belly scratches', 'Such a good boi')
INSERT INTO event VALUES ('Bowser', '2021-08-06', 'belly scratches', 'Such a good boi')

```


# Random Bits
Random stuff that I thought might be useful... to someone some time.

## Cleanup
Since we did some stuff in the UI, we'll need to clean up:

1. The Datastream itself
2. The connection profile
3. The private VPC connection (?)
4. The [private connectivity configuration](https://console.cloud.google.com/datastream/private-connections)

```
gsutil notification delete projects/_/buckets/$TARGET_BKT/notificationConfigs/menagerie-changes

gcloud pubsub topics delete menagerie-changes

```

## SQL Auth Proxy
This might be important:
https://cloud.google.com/datastream/docs/private-connectivity#cloud-sql-auth-proxy



## Some notes on SSL for Cloud SQL
https://cloud.google.com/sql/docs/mysql/configure-ssl-instance



