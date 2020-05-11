#!/bin/bash

set -x

LAB=$(echo ${AWS_PROFILE} | sed -e 's/telemetry-internal-//g')
CA_COMMON_NAME="internal-${LAB}.telemetry.tax.service.gov.uk"
DOMAIN_NAME="es.telemetry.internal"
KEY_PASSPHRASE=$(cat ../passphrase)
DAYS=90

CA_CERTIFICATE_ARN=$(aws acm-pca list-certificate-authorities \
  --query 'CertificateAuthorities[].[{arn:Arn,status:Status,cn:CertificateAuthorityConfiguration.Subject.CommonName}]' | \
  jq -r --arg cn ${CA_COMMON_NAME} '.[][] | select(.cn==$cn) | .arn')

aws acm-pca get-certificate-authority-certificate --certificate-authority-arn ${CA_CERTIFICATE_ARN} \
                                                  --output text \
                                                  --query 'Certificate' > ./ca.telemetry.internal.crt

aws acm-pca get-certificate-authority-certificate --certificate-authority-arn ${CA_CERTIFICATE_ARN} \
                                                  --output text \
                                                  --query 'CertificateChain' >> ./ca.telemetry.internal.crt

# Generate a private key
openssl genrsa -out req.key 2048

# Use the generated private key and the local config file to issue a Certificate Signing Request for the AWS Private CA
# Make note of the clientAuth AND serverAuth settings in the configuration file
openssl req -new \
            -newkey rsa:2048 \
            -config req.cnf \
            -days ${DAYS} \
            -keyout req.pem \
            -out req.csr \
            -passin pass:${KEY_PASSPHRASE} \
            -passout pass:${KEY_PASSPHRASE}

# Post request to AWS Private CA to issue a certificate for use in our Elasticsearch cluster
# Note the use of a custom template ARN in order to facilitate clientAuth and serverAuth
CERTIFICATE_ARN=$(aws acm-pca issue-certificate --certificate-authority-arn ${CA_CERTIFICATE_ARN} \
                                                --csr fileb://./req.csr \
                                                --signing-algorithm "SHA256WITHRSA" \
                                                --template-arn "arn:aws:acm-pca:::template/EndEntityCertificate/V1" \
                                                --validity Value=${DAYS},Type="DAYS" \
                                                --query 'CertificateArn' \
                                                --output text)

# The call to get-certificate returns text that's not in a great format.
# Don't be tempted to use jq, the concatenation seen here is fine.
aws acm-pca get-certificate --certificate-authority-arn ${CA_CERTIFICATE_ARN} \
                            --certificate-arn ${CERTIFICATE_ARN} \
                            --output text \
                            --query 'Certificate' > ./es.telemetry.internal.crt

aws acm-pca get-certificate --certificate-authority-arn ${CA_CERTIFICATE_ARN} \
                            --certificate-arn ${CERTIFICATE_ARN} \
                            --output text \
                            --query 'CertificateChain' >> ./es.telemetry.internal.crt

openssl pkcs12 -export \
               -in ./ca.telemetry.internal.crt \
               -nokeys \
               -out ./truststore.p12 \
               -passout pass:${KEY_PASSPHRASE}

openssl pkcs12 -export \
               -in ./es.telemetry.internal.crt \
               -inkey ./req.pem \
               -passin pass:${KEY_PASSPHRASE} \
               -out ./keystore.p12 \
               -passout pass:${KEY_PASSPHRASE}

chmod 0644 ./ca.telemetry.internal.crt
chmod 0644 ./keystore.p12
chmod 0644 ./truststore.p12
