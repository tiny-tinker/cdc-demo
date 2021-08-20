# Change Data Capture
This repo is meant as a baseline for learning and demoing change data capture. I've tried to make it as agnostic as possible with specific sections for specific CDC tools. 

Using the [menagerie example database](https://dev.mysql.com/doc/index-other.html) loaded into Cloud SQL.

Followed the MySQL configuration for Datastream [here](https://cloud.google.com/datastream/docs/configure-your-source-mysql-database#cloudsqlformysql)

**Note** Right now, the dataflow template fails and I'm unsure how to get it working. If you fix it please fork or post an issue. 

Table of Contents
=================

* [Change Data Capture](#change-data-capture)
* [Table of Contents](#table-of-contents)
* [Infra Set Up via Terraform](#infra-set-up-via-terraform)
  * [Add Some Data](#add-some-data)
* [Choose Your Own Adventure](#choose-your-own-adventure)
* [Datastream](#datastream)
  * [Create Stream](#create-stream)
  * [Add Dataflow Job](#add-dataflow-job)
* [Changing Data](#changing-data)
* [Striim](#striim)
* [Stitch](#stitch)
* [Fivetran](#fivetran)
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

echo "Bucket: \n$TARGET_BKT"
```

## Add Some Data

First, connect to the SQL instance and use the value in `$ANIMAL_PASSWD`

```bash
echo $ANIMAL_PASSWD
gcloud sql connect $INSTANCE -u animal
```

Then, create some tables and add some data:

```sql

USE menagerie;
DROP TABLE IF EXISTS event;

CREATE TABLE event
(
  name   VARCHAR(20),
  date   DATE,
  type   VARCHAR(15),
  remark VARCHAR(255)
);


DROP TABLE IF EXISTS pet;

CREATE TABLE pet
(
  name    VARCHAR(20),
  owner   VARCHAR(20),
  species VARCHAR(20),
  sex     CHAR(1),
  birth   DATE,
  death   DATE
);



INSERT INTO pet VALUES ('Bonnie','Travis','cat','f','2017-04-14',NULL);
INSERT INTO pet VALUES ('Cyde','Travis','cat','m','2017-04-14',NULL);

INSERT INTO pet VALUES ('Thelma','Travis','cat','f','2020-08-09',NULL);
INSERT INTO pet VALUES ('Louise','Travis','cat','f','2020-08-09',NULL);



INSERT INTO event VALUES ('Bonnie', '2021-08-02', 'feeding', 'Fed her treats');
INSERT INTO event VALUES ('Clyde',  '2021-08-02', 'feeding', 'Fed him treats');
INSERT INTO event VALUES ('Louise', '2021-08-03', 'belly scratches', 'Good puppy!');
INSERT INTO event VALUES ('Thelma', '2021-08-04', 'belly scratches', 'Good puppy!');


# Optional
# Then create a new user for datastream (or use the animal user)
CREATE USER 'datastream'@'%' IDENTIFIED BY '$OME_SWEET_word! here';
GRANT REPLICATION SLAVE, SELECT, RELOAD, REPLICATION CLIENT, LOCK TABLES, EXECUTE ON *.* TO 'datastream'@'%';
FLUSH PRIVILEGES;

```


# Choose Your Own Adventure
From here, you have a Cloud SQL instance with some data and a BigQuery dataset. Pick one (or all?!) of the options below to test out and learn the CDC tools. 


# Datastream


## Create Stream
After the DB is set up, we create the stream via the UI. [Link here](https://console.cloud.google.com/datastream/streams). 

**Get Started**

* Stream name
* Region - Use us-central1, unless you changed the `region` value in the Terraform variables.
* Source type - MySQL
* Destination type - Cloud Storage
* Prerequisites
   * Note: The Terraform will already enable binary logging and we already created the datastream user (or will just use the **animal** user)

**Define & test source**
* Connection profile name
* Connection details
   * Hostname or IP - This command will spit out the public IP:
```bash
   gcloud sql instances describe $INSTANCE --format="value(ipAddresses[0].ipAddress)"
```
   * Username - Use the datastream user we created or the animal user
   * Password - Use the corresponding password

**Secure connection**
I added the Terraform code to generate an SSL cert, but haven't tested this connection method yet. 

**Define connectivity method**
* Connectivity method - Choose IP allowlisting. The IPs have already been whitelisted by the Terraform code. 

**Configure stream source**
* Objects to include - Specific schemas and tables
   * Select the **menagerie** database


**Define destination**
* Connection profile name
* Bucket name - Use the bucket that was created by Terraform... or use your own. The name of the bucket is available in `$TARGET_BKT`


**Configure destination**
* Output format - Avro. Avro is a very compact file format and allows for fast reads into BigQuery.


## Add Dataflow Job

Datastream only gets it halfway. We need to use a dataflow template to get the data from the Storage bucket into BigQuery. Synthenized from [here](https://cloud.google.com/dataflow/docs/guides/templates/provided-streaming#datastream-to-bigquery).


The `$TARGET_BKT` was created with a pubsub notification that will fire whenever an object in the bucket changes. This is what the dataflow job is listening for
```bash
# Grab the project number
export PRJ_NUM=$( gcloud projects describe $PROJECT_ID --format="value(projectNumber)")

# Add some permissions to the dataflow service account
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:service-$PRJ_NUM@dataflow-service-producer-prod.iam.gserviceaccount.com" --role='roles/storage.objectAdmin'

# Also need compute admin for some reason
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:service-$PRJ_NUM@dataflow-service-producer-prod.iam.gserviceaccount.com" --role='roles/compute.admin'

# And Service Account User
gcloud projects add-iam-policy-binding $PROJECT_ID --member="serviceAccount:service-$PRJ_NUM@dataflow-service-producer-prod.iam.gserviceaccount.com" --role='roles/iam.serviceAccountUser'


# Technically this might be more secure due to least privilege
# gsutil iam ch serviceAccount:service-$PRJ_NUM@dataflow-service-producer-prod.iam.gserviceaccount.com:roles/storage.objectAdmin gs://$TARGET_BKT

# As of now, this will fail after 
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

INSERT INTO pet VALUES ('Alfred','Travis','bat','m','1971-04-14',NULL);


INSERT INTO event VALUES ('Bonnie', '2021-08-10', 'feeding', 'Fed her treats');
INSERT INTO event VALUES ('Clyde',  '2021-08-11', 'feeding', 'Fed him treats');
INSERT INTO event VALUES ('Louise', '2021-08-09', 'belly scratches', 'Good puppy!');

```

# Striim
TODO: Add Striim

# Stitch
TODO: Add Stitch data

# Fivetran

TODO: Add Fivetran

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



