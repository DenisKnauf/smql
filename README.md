Idea
====

Similar to MQL:  SMQL allowes SQL-queries on your database but in a JSON-based language.

This query language is SQL-injection-safe.
Only expencive queries can slow down your machine.

Usage
=====

Easy query in ruby:
User is a AR-Model and has a column username.
We want to find all users which has the username "auser".

	require 'smql'

	SmqlToAR.to_ar User, '{"username": "auser"}' # Query in JSON
	SmqlToAR.to_ar User, username: "auser"       # Query in Ruby

In Rails:

	SmqlToAR.to_ar User, params[:smql]

Don't forget to add gem to Gemfile:

	gem 'smql'
