#!/bin/bash

rm /etc/portage/env/*

cp -r env/ /etc/portage/
cp package.env /etc/portage/
