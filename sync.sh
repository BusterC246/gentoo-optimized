#!/bin/bash
rm /etc/portage/env/*

cp env/* /etc/portage/env
cp package.env /etc/portage/
