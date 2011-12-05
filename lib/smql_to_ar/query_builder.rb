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
			def to_s() ":smql_c#{@vid}" end
			def to_sym() "smql_c#{@vid}".to_sym end
			alias sym to_sym
			def to_i()  @vid  end
			def === other
				to_s === other || to_sym === other || to_i === other || self == other || self === other
			end
		end

		class Aliases < Hash
			def self.new prefix, *a, &e
				e ||= lambda do |h, k|
					j = Array.wrap( k).compact
					h[k] = h.key?(j) ? h[j] : "#{prefix},#{j.collect( &:to_alias).join( ',')}"
				end
				super *a, &e
			end
		end

		attr_reader :table_alias, :model, :table_model, :base_table, :_where, :_select, :_wobs, :_joins, :prefix, :_vid
		attr_accessor :logger, :limit, :offset

		def initialize model, prefix = nil
			@prefix = "smql"
			@logger = SmqlToAR.logger
			@table_alias = Aliases.new @prefix
			@_vid, @_where, @_wobs, @model, @quoter = 0, SmqlToAR::And[], {}, model, model.connection
			@base_table = [Column::Col.new( model.table_name)]
			@table_alias[ @base_table] = @base_table.first
			t = quote_table_name @base_table.first.col
			@_select, @_joins, @_joined, @_includes, @_order = ["DISTINCT #{t}.*"], "", [@base_table], [], []
			@table_model = {@base_table => @model}
		end

		def vid()  Vid.new( @_vid+=1)  end

		def inspect
			"#<#{self.class.name}:#{"0x%x"% (self.object_id<<1)}|#{@prefix}:#{@base_table}:#{@model} vid=#{@_vid} where=#{@_where} wobs=#{@_wobs} select=#{@_select} aliases=#{@table_alias}>"
		end

		# Jede via where uebergebene Condition wird geodert und alle zusammen werden geundet.
		# "Konjunktive Normalform".  Allerdings duerfen Conditions auch Komplexe Abfragen enthalten.
		# Ex: builder.where( ['a = a', 'b = c']).where( ['c = d', 'e = e']).where( 'x = y').where( ['( m = n AND o = p )', 'f = g'])
		#        #=> WHERE ( a = a OR b = c ) AND ( c = d OR e = e ) AND x = y ( ( m = n AND o = p ) OR f = g )
		def where cond
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
			name = case name
				when Array, Column::Col then @table_alias[Array.wrap name]
				else name.to_s
				end
			@quoter.quote_table_name( name).gsub /"\."/, ','
		end

		def column table, name
			"#{quote_table_name table}.#{quote_column_name name}"
		end

		def build_join orig, pretable, table, prekey, key
			" LEFT JOIN #{orig} AS #{quote_table_name table} ON #{column pretable, prekey} = #{column table, key} "
		end

		def sub_joins table, col, model, query
			prefix, base_table = "#{@prefix}_sub", col.relation.table_name
			join_ table, model, "(#{query.build( prefix).ar.to_sql})"
		end

		def join_ table, model, query, pretable = nil
			pretable ||= table[0...-1]
			@table_model[ table] = model
			premodel = @table_model[ pretable]
			t = @table_alias[ table]
			pt = quote_table_name table[ 0...-1]
			refl = premodel.reflections[table.last.to_sym]
			case refl
			when ActiveRecord::Reflection::ThroughReflection
				through = refl.through_reflection
				throughtable = table[0...-1]+[Column::Col.new( through.name, table.last.as)]
				srctable = throughtable+[Column::Col.new( refl.source_reflection.name, table.last.as)]
				@table_model[ srctable] = model
				@table_alias[ table] = @table_alias[ srctable]
				join_ throughtable, through.klass, quote_table_name( through.table_name)
				join_ srctable, refl.klass, query, throughtable
			when ActiveRecord::Reflection::AssociationReflection
				case refl.macro
				when :has_many, :has_one
					@_joins += build_join query, pretable, t, premodel.primary_key, refl.primary_key_name
				when :belongs_to
					@_joins += build_join query, pretable, t, refl.primary_key_name, premodel.primary_key
				when :has_and_belongs_to_many
					jointable = [Column::Col.new('')] + table
					@_joins += build_join refl.options[:join_table], pretable, @table_alias[jointable], premodel.primary_key, refl.primary_key_name
					@_joins += build_join query, jointable, t, refl.association_foreign_key, refl.association_primary_key
				else raise BuilderError, "Unkown reflection macro: #{refl.macro.inspect}"
				end
			else raise BuilderError, "Unkown reflection type: #{refl.class.name}"
			end
			self
		end

		def joins table, model
			table = table.flatten.compact
			return self  if @_joined.include? table # Already joined
			join_ table, model, quote_table_name( model.table_name)
			@_joined.push table
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
			ct = column table, col
			@_select.push ct
			@_order.push "#{ct} #{:DESC == o ? :DESC : :ASC}"
			self
		end

		def build_ar
			where_str = @_where.type_correction!.optimize!.build_where
			incls = {}
			@_includes.each do |inc|
				b = incls
				inc[1..-1].collect {|rel| b = b[rel] ||= {} }
			end
			@model = @model.
				select( @_select.join( ', ')).
				joins( @_joins).
				where( where_str, @_wobs).
				order( @_order.join( ', ')).
				includes( incls)
			@model = @model.limit @limit  if @limit
			@model = @model.offset @offset  if @offset
			@model
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

	class SubBuilder < Array
		attr_reader :parent, :_where
		delegate :wobs, :joins, :includes, :sub_joins, :vid, :quote_column_name, :quoter, :quote_table_name, :column, :to => :parent

		def initialize parent, tmp = false
			@parent = parent
			@parent.where self  unless @parend.nil? && tmp
		end

		def new parent, tmp = false
			super parent, tmp
			#return parent  if self.class == parent.class
			#super parent
		end

		alias where push

		def type_correction!
			collect! do |sub|
				if sub.kind_of? Array
					sub = default[ *sub]  unless sub.respond_to?( :type_correction!)
					sub.type_correction!
				end
				sub
			end
			self
		end

		def optimize!
			ext = []
			collect! do |sub|
				sub = sub.optimize!  if sub.kind_of? Array
				if self.class == sub.class
					ext.push *sub
					nil
				elsif sub.blank?
					nil
				else
					sub
				end
			end.compact!
			push *ext
			self
		end

		def inspect
			"#{self.class.name.sub( /.*::/, '')}[ #{collect(&:inspect).join ', '}]"
		end
		def default()  SmqlToAR::And  end
		def default_new( parent)  default.new self, parent, false  end
		def collect_build_where
			collect {|x| "( #{x.respond_to?( :build_where) ? x.build_where : x.to_s } )" }
		end
	end

	class And < SubBuilder
		def default; SmqlToAR::Or; end
		def build_where
			collect_build_where.join ' AND '
		end
	end

	class Or < SubBuilder
		def build_where
			collect_build_where.join ' OR '
		end
	end
end
