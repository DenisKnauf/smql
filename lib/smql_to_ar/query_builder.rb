# SmqlToAR - Builds AR-querys: Converts SMQL to ActiveRecord
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
	#######################################################################################
	# Baut die Queries zusammen.
	class QueryBuilder
		# Erzeugt einen eindeutigen Identikator "cX", wobei X iteriert wird.
		class Vid
			attr_reader :vid
			def initialize( vid)  @vid = vid  end
			def to_s() ":c#{@vid}" end
			def to_sym() "c#{@vid}".to_sym end
			alias sym to_sym
			def to_i()  @vid  end
		end

		attr_reader :table_alias, :model, :table_model, :base_table, :_where, :_select, :_wobs, :_joins
		attr_accessor :logger

		def initialize model
			@logger = SmqlToAR.logger
			@table_alias = Hash.new do |h, k|
				k = Array.wrap k
				h[k] = "smql,#{k.join(',')}"
			end
			@_vid, @_where, @_wobs, @model, @quoter = 0, [], {}, model, model.connection
			@base_table = [model.table_name.to_sym]
			@table_alias[ @base_table] = @base_table.first
			t = quote_table_name @table_alias[ @base_table]
			@_select, @_joins, @_joined, @_includes, @_order = ["DISTINCT #{t}.*"], "", [], [], []
			@table_model = {@base_table => @model}
		end

		def vid()  Vid.new( @_vid+=1)  end

		# Jede via where uebergebene Condition wird geodert und alle zusammen werden geundet.
		# "Konjunktive Normalform".  Allerdings duerfen Conditions auch Komplexe Abfragen enthalten.
		# Ex: builder.where( 'a = a', 'b = c').where( 'c = d', 'e = e').where( 'x = y').where( '( m = n AND o = p )', 'f = g')
		#        #=> WHERE ( a = a OR b = c ) AND ( c = d OR e = e ) AND x = y ( ( m = n AND o = p ) OR f = g )
		def where *cond
			@_where.push cond
			self
		end

		def wobs vals
			@_wobs.update vals
			self
		end

		def quote_column_name name
			@quoter.quote_column_name( name).gsub /"\."/, ','
		end

		def quote_table_name name
			@quoter.quote_table_name( name).gsub /"\."/, ','
		end

		def column table, name
			"#{quote_table_name table.kind_of?(String) ? table : @table_alias[table]}.#{quote_column_name name}"
		end

		def build_join orig, pretable, table, prekey, key
			" JOIN #{quote_table_name orig.to_sym} AS #{quote_table_name table} ON #{column pretable, prekey} = #{column table, key} "
		end

		def join table, model
			return self  if @_joined.include? table # Already joined
			pretable = table[0...-1]
			@table_model[ table] = model
			premodel = @table_model[ pretable]
			t = @table_alias[ table]
			pt = quote_table_name @table_alias[ table[ 0...-1]]
			refl = premodel.reflections[table.last]
			case refl.macro
			when :has_many
				@_joins += build_join model.table_name, pretable, t, premodel.primary_key, refl.primary_key_name
			when :belongs_to
				@_joins += build_join model.table_name, pretable, t, refl.primary_key_name, premodel.primary_key
			when :has_and_belongs_to_many
				jointable = [','] + table
				@_joins += build_join refl.options[:join_table], pretable, @table_alias[jointable], premodel.primary_key, refl.primary_key_name
				@_joins += build_join model.table_name, jointable, t, refl.association_foreign_key, refl.association_primary_key
			else raise BuilderError, "Unkown reflection macro: #{refl.macro.inspect}"
			end
			@_joined.push table
			self
		end

		def includes table
			@_includes.push table
			self
		end

		def select col
			@_select.push quote_column_name( @table_alias[col])
			self
		end

		def order table, col, o
			tc = column table, col
			@_select.push ct
			@_order.push "#{ct} #{:DESC == o ? :DESC : :ASC}"
			self
		end

		class Dummy
			def method_missing m, *a, &e
				#p :dummy => m, :pars => a, :block => e
				self
			end
		end

		def build_ar
			where_str = @_where.collect do |w|
				w = Array.wrap w
				1 == w.length ? w.first : "( #{w.join( ' OR ')} )"
			end.join ' AND '
			incls = {}
			@_includes.each do |inc|
				b = incls
				inc[1..-1].collect {|rel| b = b[rel] ||= {} }
			end
			@logger.debug incls: incls, joins: @_joins
			@model = @model.
				select( @_select.join( ', ')).
				joins( @_joins).
				where( where_str, @_wobs).
				order( @_order.join( ', ')).
				includes( incls)
		end

		def fix_calculate
			def @model.calculate operation, column_name, options = nil
				options = options.try(:dup) || {}
				options[:distinct] = true  unless options.except(:distinct).present?
				column_name = klass.primary_key  unless column_name.present?
				super operation, column_name, options
			end
			self
		end

		def to_ar
			build_ar
			fix_calculate
			@model
		end
	end
end
