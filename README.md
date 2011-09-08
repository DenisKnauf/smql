Idea
====

Similar to MQL:  SMQL allows to perform queries on your database but in a JSON-based language.

This query language is SQL-injection-safe.
However, expensive queries can slow down your machine.

Usage
=====

Example: An easy query in ruby:
User is a ActiveRecord-Model and has a column username.
We want to find all _users_ _where_ _username_ = _"auser"_.

	require 'smql'

	SmqlToAR.to_ar User, '{"username": "auser"}' # Query in JSON
	SmqlToAR.to_ar User, username: "auser"       # Query in Ruby

In Rails:

	SmqlToAR.to_ar User, params[:smql]

Don't forget to add my gem to the _Gemfile_:

	gem 'smql'
