# SmqlToAR - Base library: Converts SMQL to ActiveRecord
# Copyright (C) 2011 Denis Knauf
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

class SmqlToAR
	module Assertion
		def raise_unless cond, exception = nil, *args
			cond, exception, *args = yield. cond, exception, *args  if block_given?
			raise exception || Exception, *args  unless cond
		end

		def raise_if cond, exception = nil, *args
			cond, exception, *args = yield. cond, exception, *args  if block_given?
			raise exception || Exception, *args  if cond
		end
	end

	include ActiveSupport::Benchmarkable
	############################################################################r
	# Exceptions

	class SMQLError < Exception
		attr_reader :data
		def initialize data
			@data = data
			super data.inspect
		end
	end

	# Ein Fehler ist in einem Subquery aufgetreten.
	# Die eigentliche Exception wird in @data[:exception] hinterlegt.
	class SubSMQLError < SMQLError
		def initialize query, model, exception
			ex = {:class => exception.class, :message => exception.message}
			ex[:data] = exception.data  if exception.respond_to? :data
			super :query => query, :model => model.to_s, :exception => ex
			set_backtrace exception.backtrace
		end
 	end

	class ParseError < SMQLError; end

	# Malformed ColOp
	class UnexpectedColOpError < ParseError
		def initialize model, colop, val
			super :got => colop, :val => val, :model => model.to_s
		end
	end

	class UnexpectedError < ParseError
		def initialize model, colop, val
			super :got => {colop => val}, :model => model.to_s
		end
	end

	class NonExistingSelectableError < SMQLError
		def initialize got
			super :got => got
		end
	end

	class NonExistingColumnError < SMQLError
		def initialize expected, got
			super :expected => expected, :got => got
		end
	end

	class NonExistingRelationError < SMQLError
		def initialize expected, got
			super :expected => expected, :got => got
		end
	end

	class ProtectedColumnError < SMQLError
		def initialize protected_column
			super :protected_column => protected_column
		end
 	end

	class RootOnlyFunctionError < SMQLError
		def initialize path
			super :path => path
		end
	end

	class ConColumnError < SMQLError
		def initialize expected, got
			super :expected => expected, :got => got
		end
	end

	class UnknownHavingMethod < SMQLError
		def initialize expected, got
			super :expected => expected, :got => got
		end
	end

	class BuilderError < Exception; end

	#############################################################################

	# Model der Relation `rel` von `model`
	def self.model_of model, rel
		rel = rel.to_sym
		r = model.reflections[ rel].andand.klass
		r.nil? && :self == rel ? model : r
	end

	# Eine Spalte in einer Tabelle, relativ zu `Column#model`.
	# Kann auch einen Pfad `Column#path` haben,  wobei `Column#col` dann
	# eine Relation von dem Model der letzten Relation von `Column#path` ist.
	class Column
		include Enumerable
		attr_reader :path, :col
		attr_accessor :model

		def initialize model, *col
			@model = model
			@last_model = nil
			*@path, @col = *Array.wrap( col).collect( &it.to_s.split( /[.\/]/)).flatten.collect( &:to_sym).reject( &it==:self)
		end

		def last_model
			@last_model ||= each{}
		end

		def each
			model = @model
			@path.each do |rel|
				rel = rel.to_sym
				unless :self == rel
					model = SmqlToAR.model_of model, rel
					return false  unless model
					yield rel, model
				end
			end
			model
		end

		def exist_in?
			model = last_model
			return false  unless model
			model.column_names.include? @col.to_s
		end

		def protected?
			model = @model
			each do |rel, _model|
				pr = Array.wrap model.respond_to?( :smql_protected) ? model.smql_protected : nil
				pr.include? rel.to_s
				model = _model
			end
			pr = Array.wrap model.respond_to?( :smql_protected) ? model.smql_protected : nil
			pr.include? @col.to_s
		end

		def joins builder = nil, table = nil, &exe
			pp = []
			table = Array.wrap table
			exe ||= builder ? lambda {|j, m| builder.joins table+j, m} : Array.method( :[])
			collect do |rel, model|
				pp.push rel
				exe.call pp, model
			end
	 	end
		def self?()  !@col  end
		def length() @path.length+(self.self? ? 0 : 1)  end
		def size()   @path.size+(self.self? ? 0 : 1)  end
		def to_a()   @path+(self.self? ? [] : [@col])  end
		def to_s()   to_a.join '.'  end
		def to_sym() to_s.to_sym  end
		def to_json()  to_s  end
		def inspect()  "#<Column: #{model} #{to_s}>"  end
		def relation()  self.self? ? model : SmqlToAR.model_of( last_model, @col)  end
		def allowed?()  ! self.protected?  end
		def child?()  @path.empty? and !!relation  end
	end

	attr_reader :model, :query, :conditions, :builder, :order
	attr_accessor :logger
	if defined? Rails
		class Railtie < ::Rails::Railtie
			initializer "active_record.logger" do
				SmqlToAR.logger = ::Rails.logger
			end
		end
	else
		require 'logger'
		@@logger = Logger.new $stdout
	end

	class <<self
		def logger=(logger)  @@logger = logger  end
		def logger()  @@logger  end
	end

	def initialize model, query, order = nil
		query = JSON.parse query  if query.kind_of? String
		@model, @query, @logger, @order = model, query, @@logger, order
		#p model: @model, query: @query
	end

	def self.models models
		models = Array.wrap models
		r = Hash.new {|h,k| h[k] = {} }
		while model = models.tap( &:uniq!).pop
			refls = model.respond_to?( :reflections) && model.reflections
			refls && refls.each do |name, refl|
				r[model.name][name] = case refl
					when ActiveRecord::Reflection::ThroughReflection then {:macro => refl.macro, :model => refl.klass.name, :through => refl.through_reflection.name}
					when ActiveRecord::Reflection::AssociationReflection then {:macro => refl.macro, :model => refl.klass.name}
					else raise "Ups: #{refl.class}"
					end
				models.push refl.klass  unless r.keys.include? refl.klass.name
			end
		end
		r
	end

	def parse
		benchmark 'SMQL parse' do
			@conditions = ConditionTypes.try_parse @model, @query
		end
		#p conditions: @conditions
		self
	end

	def build prefix = nil
		benchmark 'SMQL build query' do
			@builder = QueryBuilder.new @model, prefix
			table = @builder.base_table
			@conditions.each &it.build( builder, table)
		end
		#p builder: @builder
		self
	end

	def ar
		@ar ||= benchmark 'SMQL ar' do
			@builder.to_ar
		end
	end

	def to_ar
		benchmark 'SMQL' do
			parse
			build
			ar
		end
	end

	def self.to_ar *params
		new( *params).to_ar
	end

	def self.reload_library
		lib_dir = File.dirname __FILE__
		fj = lambda {|*a| File.join lib_dir, *a }
		load fj.call( 'smql_to_ar.rb')
		load fj.call( 'smql_to_ar', 'condition_types.rb')
		load fj.call( 'smql_to_ar', 'query_builder.rb')
	end
end
