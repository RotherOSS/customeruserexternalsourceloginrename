.. toctree::
    :maxdepth: 2
    :caption: Contents

Sacrifice to Sphinx
===================

Description
===========
Rename customer users that are sourced from an external source like LDAP.

Information about customer users might be stored in external sources. In that cases the need might arise to
change the login. An example is when the first and last name is used as the login name. Especially the
last name might not be stable, for example when the customer user marries.

This package provides the console command, `Admin::CustomerUser::ExternalSourceLoginRename` that helps in switching customer user names.
That command triggers the same event as the event that is triggered when an internal source customer login is changed.
For example the method `TicketCustomerSet()` is called for setting the customer user of tickets.

The console command requires that both the old and the new login name are declared in the customer user map.

System requirements
===================

Framework
---------
OTOBO 11.1.x

Packages
--------
\-

Third-party software
--------------------
\-

Usage
=====

Setup
-----

Configuration Reference
-----------------------

No configuration is needed.

About
=======

Contact
-------
| Rother OSS GmbH
| Email: hello@otobo.de
| Web: https://otobo.de

Version
-------
Author: |doc-vendor| / Version: |doc-version| / Date of release: |doc-datestamp|
