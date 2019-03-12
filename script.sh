#!/bin/bash



set -e

#######
#Input#
#######

echo "Enter Domain ?"
read  domain

echo "enter Customer email?(plz be careful!):"
read  mail



####################
#Generate Passwords#
####################

#Generate Random string to use as mysql root password
mysql_root_passwd=$(head -c 8  /dev/random | md5sum | cut -c1-10 )
echo $(date)":"$hostname":Wordpress_Mysql:"$mysql_root_passwd >> /home/ansible/install_logs
 
#Generate Random string to use as  root password
root_passwd=$(head -c 8  /dev/random | md5sum | cut -c1-10 )
root_hash=`echo $root_passwd |  openssl md5 | awk -F '= ' '{print $2}'`

#Generate Random string to use as  ftp-user password
ftp_passwd=$(head -c 8  /dev/random | md5sum | cut -c1-10 )
ftp_hash=`echo $ftp_password |  openssl md5 | awk -F '= ' '{print $2}'`


###########
#Provision#
###########

id=`echo "$domain" | awk -F '.' '{print $1 $2}' | sed 's/\-//g'`
hostname=$id

#Instances

##create
echo " creating instances ,, "
aws lightsail create-instances  --instance-names "$domain"_inst1 --availability-zone us-east-1a --bundle-id nano_2_0 --blueprint-id wordpress_4_9_8 --user-data file://'/usr/bin/userdata.sh'  > /dev/null
aws lightsail create-instances  --instance-names "$domain"_inst2 --availability-zone us-east-1a --bundle-id nano_2_0 --blueprint-id wordpress_4_9_8 --user-data file://'/usr/bin/userdata.sh'  > /dev/null
#Allocate_static_ip
echo " Allocate Static IPs .. "
aws lightsail allocate-static-ip --static-ip-name "$domain"_ip1 > /dev/null
aws lightsail allocate-static-ip --static-ip-name "$domain"_ip2 > /dev/null
##get local ips
localip1=`aws lightsail get-instance --instance-name "$domain"_inst1 | jq -r .instance.privateIpAddress`
localip2=`aws lightsail get-instance --instance-name "$domain"_inst2 | jq -r .instance.privateIpAddress`
cidr1="$localip1/32"
cidr2="$localip2/32"
##open ports


#Security_Group 

echo " Creating security group ,, "

##create_for_RDS
aws ec2  create-security-group --description domain"$domain" --group-name "$domain"_sg  --vpc-id vpc-502fa02b > /dev/null
sg_id=`aws ec2 describe-security-groups --group-name "$domain"_sg | jq -r .SecurityGroups[].GroupId`
##open_ports_from_instances
aws ec2 authorize-security-group-ingress --group-id $sg_id --protocol tcp --port 3306 --cidr $cidr1
aws ec2 authorize-security-group-ingress --group-id $sg_id --protocol tcp --port 3306 --cidr $cidr2



#RDS 
echo " Creating RDS instance ,,it will take about 5 minutes "

db_name="$id"db
rds_name="$id"rds
aws rds create-db-instance --db-name "$id"db --db-instance-identifier  "$id"rds --allocated-storage 20 --db-instance-class db.t2.micro --engine mysql --master-username root --master-user-password $mysql_root_passwd --vpc-security-group-ids $sg_id --availability-zone us-east-1a > /dev/null
sleep 350
dbstatus=`aws rds describe-db-instances --db-instance-identifier "$id"rds | jq -r .DBInstances[].DBInstanceStatus`
while  [ "$dbstatus" != "available" ]  ; do
dbstatus=`aws rds describe-db-instances --db-instance-identifier "$id"rds | jq -r .DBInstances[].DBInstanceStatus`
echo "Checking for DB instance ... still creating "
sleep 10
done
echo "Checking for DB instance ... Done!"
sleep 5
rds_endpoint=$rds_name".c9hbae3b9azs.us-east-1.rds.amazonaws.com"

#Attach_Static_IP

echo " Attaching Static IP address ,, "

aws lightsail attach-static-ip --static-ip-name "$domain"_ip1  --instance-name "$domain"_inst1 > /dev/null
aws lightsail attach-static-ip --static-ip-name "$domain"_ip2  --instance-name "$domain"_inst2 > /dev/null
staticip1=`aws lightsail get-static-ip --static-ip-name "$domain"_ip1 | jq -r .staticIp.ipAddress`
staticip2=`aws lightsail get-static-ip --static-ip-name "$domain"_ip2 | jq -r .staticIp.ipAddress`




#ELB

echo " Configuring ELB ,, "

aws elbv2 create-load-balancer --name "$id"-lb --subnets subnet-ff31f5b5 subnet-bca6b7d8 > /dev/null
lb_arn=`aws elbv2 describe-load-balancers --names "$id"-lb | jq -r .LoadBalancers[].LoadBalancerArn` > /dev/null
aws elbv2 create-target-group --name "$id"-lb-tg --protocol HTTP --port 80 --health-check-path /index.php --matcher HttpCode=301 --target-type ip --vpc-id vpc-502fa02b > /dev/null
tg_arn=`aws elbv2 describe-target-groups --names "$id"-lb-tg | jq -r .TargetGroups[].TargetGroupArn` > /dev/null
aws elbv2 modify-target-group-attributes --target-group-arn  $tg_arn --attributes Key=stickiness.enabled,Value=true Key=stickiness.type,Value=lb_cookie Key=stickiness.lb_cookie.duration_seconds,Value=300 > /dev/null 
aws elbv2 register-targets --target-group-arn $tg_arn --targets Id=$localip1,AvailabilityZone=all Id=$localip2,AvailabilityZone=all > /dev/null
aws elbv2 create-listener --load-balancer-arn $lb_arn --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn=$tg_arn > /dev/null
dns=`aws elbv2 describe-load-balancers --names "$id"-lb | jq -r .LoadBalancers[].DNSName`



# S3

echo "Creating S3 Bucket and attaching default bucket policy ,,"
sleep 5
s3="$id"bucket
aws s3api create-bucket --bucket $s3 --region us-east-1 > /dev/null
cp /usr/bin/s3policy.json /usr/bin/s3policy_"$id".json
sed -i "s/exalight1/${s3}/g" /usr/bin/s3policy_"$id".json
aws s3api put-bucket-policy --bucket $s3 --policy file:///usr/bin/s3policy_"$id".json > /dev/null



#IAM

echo "creating IAM User"
sleep 5
aws iam create-user --user-name $id"user" > /dev/null
iam_secret=`aws iam create-access-key --user-name "$id"user | jq -r .AccessKey.SecretAccessKey`
iam_access=`aws iam list-access-keys --user-name "$id"user  | jq -r .AccessKeyMetadata[].AccessKeyId`

echo " Allowing write access to the user on the S3 bucket ,, "
sleep 5
cp /usr/bin/userpolicy.json /usr/bin/userpolicy_"$id".json
sed -i "s/bucket1/${s3}/g" /usr/bin/userpolicy_"$id".json
policy_arn=`aws iam create-policy --policy-name "$id"-policy --policy-document file:///usr/bin/userpolicy_"$id".json | jq -r .Policy.Arn`
aws iam attach-user-policy --policy-arn $policy_arn --user-name $id"user" > /dev/null


###############
###Configure###
###############



virginia_key="/home/ansible/vkey.key"

newhost1=$hostname"_inst1 ansible_host="$staticip1" ansible_user="ubuntu" ansible_ssh_private_key_file="$virginia_key" state=master"
newhost2=$hostname"_inst2 ansible_host="$staticip2" ansible_user="ubuntu" ansible_ssh_private_key_file="$virginia_key
echo "[lightsail]" > /home/ansible/hosts/lightsail
echo $newhost1 >> /home/ansible/hosts/lightsail 
echo $newhost2 >> /home/ansible/hosts/lightsail 
echo "[lightsail:vars]" >> /home/ansible/hosts/lightsail
echo "mysql_root_passwd="$mysql_root_passwd  >> /home/ansible/hosts/lightsail
echo "rds_endpoint="$rds_endpoint >> /home/ansible/hosts/lightsail
echo "web_endpoint="$dns >> /home/ansible/hosts/lightsail
echo "id="$id >> /home/ansible/hosts/lightsail
echo "ansible_python_interpreter=/usr/bin/python3" >> /home/ansible/hosts/lightsail
echo "db_name="$db_name >> /home/ansible/hosts/lightsail
echo "localip1="$localip1 >> /home/ansible/hosts/lightsail
echo "localip2="$localip2 >> /home/ansible/hosts/lightsail
echo "email="$mail  >> /home/ansible/hosts/lightsail
echo "domain="$domain  >> /home/ansible/hosts/lightsail
echo "root_passwd="$root_passwd  >> /home/ansible/hosts/lightsail
echo "ftp_passwd="$ftp_passwd  >> /home/ansible/hosts/lightsail
echo "ftp_hash="$ftp_hash  >> /home/ansible/hosts/lightsail
echo "root_hash="$root_hash  >> /home/ansible/hosts/lightsail
echo "iam_secret="$iam_secret  >> /home/ansible/hosts/lightsail
echo "iam_secret="$iam_access  >> /home/ansible/hosts/lightsail
echo "s3="$s3  >> /home/ansible/hosts/lightsail


echo "Configuring Instances ,, "
sleep 5
ansible-playbook -i /home/ansible/hosts/lightsail /home/ansible/lightsail.yml 
#ansible-playbook -i /home/ansible/hosts/lightsail /home/ansible/lightsail-slave.yml > /dev/null
wordpressadmin=`cat /home/bitnami_password/"$id"_inst1/home/bitnami/bitnami_application_password`

echo "WEB ENDPOINT is: " $dns
echo "wordpress password is: " $wordpressadmin
echo "Attached static IP to instance 1 is: "$staticip1
echo "Attached static IP to instance 2 is: "$staticip2
echo "root password is: " $root_passwd
echo "RDS endpoint is: "$rds_endpoint

php /home/mail/send_lightsail_wordpress.php $mail $hostname $mysql_root_passwd $domain $id $dns $ftp_passwd
