#!/usr/bin/env python3

import argparse
import os
import sys
from datetime import datetime, timedelta

import boto3
import pytz
from botocore.client import ClientError, Config
from dateutil.parser import parse

# "backup_bucket" must be a universally unique name, so choose something
# specific to your setup.
# The bucket will be created in your account if it does not already exist
backup_bucket = os.environ['MYBUCKETNAME']
access_key = os.environ['MYACCESSKEY']
secret_key = os.environ['MYSECRETKEY']
endpoint_url = os.environ['MYENDPOINTURL']
region_name = os.environ['MYREGIONNAME']


class Space():
    def __init__(self, bucket):
        self.session = boto3.session.Session()
        self.client = self.session.client('s3',
                                          region_name=region_name,
                                          endpoint_url=endpoint_url,
                                          aws_access_key_id=access_key,
                                          aws_secret_access_key=secret_key,
                                          config=Config(signature_version='s3')
                                          )
        self.bucket = bucket
        self.paginator = self.client.get_paginator('list_objects')

    def create_bucket(self):
        try:
            self.client.head_bucket(Bucket=self.bucket)
        except ClientError as e:
            if e.response['Error']['Code'] == '404':
                self.client.create_bucket(Bucket=self.bucket)
            elif e.response['Error']['Code'] == '403':
                print("The bucket name \"{}\" is already being used by "
                      "someone.  Please try using a different bucket "
                      "name.".format(self.bucket))
                sys.exit(1)
            else:
                print("Unexpected error: {}".format(e))
                sys.exit(1)

    def upload_files(self, files):
        for filename in files:
            self.client.upload_file(Filename=filename, Bucket=self.bucket,
                                    Key=os.path.basename(filename))
            print("Uploaded {} to \"{}\"".format(filename, self.bucket))

    def remove_file(self, filename):
        self.client.delete_object(Bucket=self.bucket,
                                  Key=os.path.basename(filename))

    def prune_backups(self, days_to_keep):
        oldest_day = datetime.now(pytz.utc) - timedelta(days=int(days_to_keep))
        try:
            # Create an iterator to page through results
            page_iterator = self.paginator.paginate(Bucket=self.bucket)
            # Collect objects older than the specified date
            objects_to_prune = [filename['Key'] for page in page_iterator
                                for filename in page['Contents']
                                if filename['LastModified'] < oldest_day]
        except KeyError:
            # If the bucket is empty
            sys.exit()
        for object in objects_to_prune:
            print("Removing \"{}\" from {}".format(object, self.bucket))
            self.remove_file(object)

    def download_file(self, filename):
        self.client.download_file(Bucket=self.bucket,
                                  Key=filename, Filename=filename)

    def get_day(self, day_to_get):
        try:
            # Attempt to parse the date format the user provided
            input_date = parse(day_to_get)
        except ValueError:
            print("Cannot parse the provided date: {}".format(day_to_get))
            sys.exit(1)
        day_string = input_date.strftime("-%m-%d-%Y_")
        print_date = input_date.strftime("%A, %b. %d %Y")
        print("Looking for objects from {}".format(print_date))
        try:
            # create an iterator to page through results
            page_iterator = self.paginator.paginate(Bucket=self.bucket)
            objects_to_grab = [filename['Key'] for page in page_iterator
                               for filename in page['Contents']
                               if day_string in filename['Key']]
        except KeyError:
            print("No objects currently in bucket")
            sys.exit()
        if objects_to_grab:
            for object in objects_to_grab:
                print("Downloading \"{}\" from {}".format(object, self.bucket))
                self.download_file(object)
        else:
            print("No objects found from: {}".format(print_date))
            sys.exit()


def is_valid_file(filename):
    if os.path.isfile(filename):
        return filename
    else:
        raise argparse.ArgumentTypeError("File \"{}\" does not exist."
                                         .format(filename))


def parse_arguments():
    parser = argparse.ArgumentParser(
        description='''Client to perform backup-related tasks with
                     object storage.''')
    subparsers = parser.add_subparsers()

    # parse arguments for the "upload" command
    parser_upload = subparsers.add_parser('upload')
    parser_upload.add_argument('files', type=is_valid_file, nargs='+')
    parser_upload.set_defaults(func=upload)

    # parse arguments for the "prune" command
    parser_prune = subparsers.add_parser('prune')
    parser_prune.add_argument('--days-to-keep', default=30)
    parser_prune.set_defaults(func=prune)

    # parse arguments for the "download" command
    parser_download = subparsers.add_parser('download')
    parser_download.add_argument('filename')
    parser_download.set_defaults(func=download)

    # parse arguments for the "get_day" command
    parser_get_day = subparsers.add_parser('get_day')
    parser_get_day.add_argument('day')
    parser_get_day.set_defaults(func=get_day)

    return parser.parse_args()


def upload(space, args):
    space.upload_files(args.files)


def prune(space, args):
    space.prune_backups(args.days_to_keep)


def download(space, args):
    space.download_file(args.filename)


def get_day(space, args):
    space.get_day(args.day)


def main():
    args = parse_arguments()
    space = Space(bucket=backup_bucket)
    space.create_bucket()
    args.func(space, args)


if __name__ == '__main__':
    main()
