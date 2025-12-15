import boto3
import os
import sys
import uuid
import json
from urllib.parse import unquote_plus
from PIL import Image
import PIL.Image
            
s3_client = boto3.client('s3')
            
def resize_image(image_path, resized_path):
  with Image.open(image_path) as image:
    image.thumbnail(tuple(x / 2 for x in image.size))
    image.save(resized_path)
            
def handler(event, context):
  for record in event['Records']:
    sns_message = json.loads(record['body'])

    s3_event = json.loads(sns_message['Message'])

    for s3_record in s3_event['Records']:
      bucket = s3_record['s3']['bucket']['name']
      key = unquote_plus(s3_record['s3']['object']['key'])
      tmpkey = key.replace('/', '')
      download_path = '/tmp/{}{}'.format(uuid.uuid4(), tmpkey)
      upload_path = '/tmp/resized-{}'.format(tmpkey)
      s3_client.download_file(bucket, key, download_path)
      resize_image(download_path, upload_path)
      s3_client.upload_file(upload_path, 'sqs-lab-output-bucket', 'resized-{}'.format(key))