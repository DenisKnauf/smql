# SmqlToAR - Parser: Converts SMQL to ActiveRecord
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
	#############################################################################
	# Alle Subklassen (qualitativ: ConditionTypes::*), die als Superklasse Condition haben,
	#  stellen eine Regel dar,  unter diesen sie das gesuchte Objekt annehmen.
	# Nimmt eine solche Klasse ein Object nicht an,  so wird die naechste Klasse ausprobiert.
	# Es wird in der Reihenfolge abgesucht,  in der #constants die Klassen liefert,
	#  wobei angenommen wird,  dass diese nach dem Erstellungszeitpunkt sortiert sind,
	#  aeltere zuerst.
	# Nimmt eine Klasse ein Objekt an,  so soll diese Klasse instanziert werden.
	# Alles weitere siehe Condition.
	module ConditionTypes
		extend SmqlToAR::Assertion

		class <<self
			# Ex: 'givenname|surname|nick' => [:givenname, :surname, :nick]
			def split_keys k
				k.split( '|').collect &:to_sym
			end

			def conditions &e
				unless block_given?
					r = Enumerator.new( self, :conditions)
					s = self
					r.define_singleton_method :[] do |k|
						s.conditions.select {|c| c::Operator === k }
					end
					return r
				end
				constants.each do |c|
					next  if :Condition == c
					c = const_get c
					next  if Condition === c
					yield c
				end
			end

			# Eine Regel parsen.
			# Ex: Person, "givenname=", "Peter"
			def try_parse_it model, colop, val
				r = nil
				#p :try_parse => { :model => model, :colop => colop, :value => val }
				conditions.each do |c|
					raise_unless colop =~ /^(?:\d*:)?(.*?)(\W*)$/, UnexpectedColOpError.new( model, colop, val)
					col, op = $1, $2
					col = split_keys( col).collect {|c| Column.new model, c }
					r = c.try_parse model, col, op, val
					break  if r
				end
				raise_unless r, UnexpectedError.new( model, colop, val)
				r
			end

			# Alle Regeln parsen.  Die Regeln sind in einem Hash der Form {colop => val}
			# Ex: Person, {"givenname=", "Peter", "surname=", "Mueller"}
			def try_parse model, colopvals
				colopvals.collect do |colop, val|
					#p :try_parse => { colop: colop, val: val, model: model }
					try_parse_it model, colop, val
				end
			rescue SMQLError => e
				raise SubSMQLError.new( colopvals, model, e)
			end

			# Erstellt eine Condition fuer eine Regel.
			def simple_condition superclass, op = nil, where = nil, expected = nil
				cl = Class.new superclass
				cl.const_set :Operator, op  if op
				cl.const_set :Where, where  if where
				cl.const_set :Expected, expected  if expected
				cl
			end
		end

		class Condition
			include SmqlToAR::Assertion
			extend SmqlToAR::Assertion
			attr_reader :value, :cols
			Operator = nil
			Expected = []
			Where = nil

			class <<self
				# Versuche das Objekt zu erkennen.  Operator und Expected muessen passen.
				# Passt das Object,  die Klasse instanzieren.
				def try_parse model, cols, op, val
					#p :self => name, :try_parse => op, :cols => cols, :with => self::Operator, :value => val, :expected => self::Expected, :model => model.name
					new model, cols, val  if self::Operator === op and self::Expected.any?( &it === val)
				end

				def inspect
					"#{self.name}(:operator=>#{self::Operator.inspect}, :expected=>#{self::Expected.inspect}, :where=>#{self::Where.inspect})"
				end
			end

			def initialize model, cols, val
				@model, @cols = model, cols
				@value = case val
					when Hash, Range then val
					else Array.wrap val
					end
				verify
			end

			def inspect
				"#<#{self.class.name}:0x#{(self.object_id<<1).to_s 16} model: #{self.class.name}, cols: #{@cols.inspect}, value: #{@value.inspect}>"
			end

			def verify
				@cols.each do |col|
					verify_column col
					verify_allowed col
				end
			end

			# Gibt es eine Spalte diesen Namens?
			# Oder:  Gibt es eine Relation diesen Namens?  (Hier nicht der Fall)
			def verify_column col
				raise_unless col.exist_in?, NonExistingColumnError.new( %w[Column], col)
			end

			# Modelle koennen Spalten/Relationen verbieten mit Model#smql_protected.
			# Dieses muss ein Object mit #include?( name_als_string) zurueckliefern,
			# welches true fuer verboten und false fuer, erlaubt steht.
			def verify_allowed col
				raise_if col.protected?, ProtectedColumnError.new( col)
			end

			# Erstelle alle noetigen Klauseln. builder nimmt diese entgegen,
			# wobei builder.joins, builder.select, builder.where und builder.wobs von interesse sind.
			# mehrere Schluessel bedeuten, dass die Values _alle_ zutreffen muessen, wobei die Schluessel geODERt werden.
			# Ex:
			# 1) {"givenname=", "Peter"} #=> givenname = 'Peter'
			# 2) {"givenname=", ["Peter", "Hans"]} #=> ( givenname = 'Peter' OR givenname = 'Hans' )
			# 3) {"givenname|surname=", ["Peter", "Mueller"]}
			#       #=> ( givenname = 'Peter' OR surname = 'Peter' ) AND ( givenname = 'Mueller' OR surname = 'Mueller' )
			def build builder, table
				values = Hash[ @value.collect {|value| [ builder.vid, value ] } ]
				values.each {|k, v| builder.wobs k.sym => v }
				if 1 == @cols.length
					@cols.each do |col|
						col.joins builder, table
						col = builder.column table+col.path, col.col
						builder.where values.keys.collect {|vid| self.class::Where % [ col, vid.to_s ] }
					end
				else
					values.keys.each do |vid|
						builder.where @cols.collect {|col|
								col.joins builder, table
								col = builder.column table+col.path, col.col
								self.class::Where % [ col, vid.to_s ]
							}
					end
				end
				self
			end
		end

		class NotInRange < Condition
			Operator = '!..'
			Where = "%s NOT BETWEEN %s AND %s"
			Expected = [Range, lambda {|val| Array === val && 2 == val.length } ]

			def initialze model, cols, val
				if Array === val && 2 == val.length
					f, l = val
					f, l = Time.parse(f), Time.parse(l)  if f.kind_of? String
					val = f..l
				end
				super model, cols, val
			end

			def build builder, table
				builder.wobs (v1 = builder.vid) => @value.begin, (v2 = builder.vid) => @value.end
				@cols.each do |col|
					col.joins builder, table
					builder.where self.class::Where % [ builder.column( table+col.path, col.col), v1, v2]
				end
				self
			end
		end
		InRange = simple_condition NotInRange, '..', "%s BETWEEN %s AND %s"

		class NotIn < Condition
			Operator = '!|='
			Where = "%s NOT IN (%s)"
			Expected = [Array]

			def build builder, table
				builder.wobs (v = builder.vid).to_sym => @value
				@cols.each do |col|
					col.joins builder, table
					builder.where self.class::Where % [ builder.column( table+col.path, col.col), v.to_s]
				end
				self
			end
		end

		In = simple_condition NotIn, '|=', '%s IN (%s)', [Array]
		In2 = simple_condition In, '', nil, [Array]
		NotEqual = simple_condition Condition, '!=', "%s <> %s", [Array, String, Numeric]
		NotEqual2 = simple_condition Condition, '<>', "%s <> %s", [Array, String, Numeric]
		GreaterThanOrEqual = simple_condition Condition, '>=', "%s >= %s", [Array, Numeric]
		LesserThanOrEqual = simple_condition Condition, '<=', "%s <= %s", [Array, Numeric]

		# Examples:
		# { 'articles=>' => { id: 1 } }
		# { 'articles=>' => [ { id: 1 }, { id: 2 } ] }
		class EqualJoin <Condition
			Operator = '=>'
			Expected = [Hash, lambda {|x| x.kind_of?( Array) and x.all?( &it.kind_of?( Hash))}]

			def initialize *pars
				super( *pars)
				@value = Array.wrap @value
				cols = {}
				p self: self, cols: @cols
				@cols.each do |col|
					col_model = col.relation
					cols[col] = [col_model] + @value.collect {|val| ConditionTypes.try_parse( col_model, val) }
				end
				@cols = cols
			end

			def verify_column col
				raise_unless col.relation, NonExistingRelationError.new( %w[Relation], col)
			end

			def build builder, table
				@cols.each do |col, sub|
					model, *sub = sub
					t = table + col.path + [col.col]
					col.joins.each {|j, m| builder.joins table+j, m }
					builder.joins t, model
					b2 = 1 == sub.length ? builder : Or.new( builder)
					sub.each {|i| i.collect( &it.build( And.new( b2), t)); p 'or' => b2 }
				end
				ap '=>' => builder
				self
			end
		end

		# Takes to Queries.
		# First Query will be a Subquery, second a regular query.
		# Example:
		#   Person.smql 'sub.articles:' => [{'limit:' => 1, 'order:': 'updated_at desc'}, {'content~' => 'some text'}]
		# Person must have as last Article (compared by updated_at) owned by Person a Artive which has 'some text' in content.
		# The last Article needn't to have 'some text' has content,  the subquery takes it anyway.
		# But the second query compares to it and never to any other Article,  because these are filtered by first query.
		# The difference to
		#   Person.smql :articles => {'content~' => 'some text', 'limit:' => 1, 'order:': 'updated_at desc'}
		# is,  second is not allowed (limit and order must be in root) and this means something like
		#   "Person must have the Article owned by Person which has 'some text' in content.
		#   limit and order has no function in this query and this article needn't to be the last."
		class SubEqualJoin < EqualJoin
			Operator = '()'
			Expected = [lambda {|x| x.kind_of?( Array) and (1..2).include?( x.length) and x.all?( &it.kind_of?( Hash))}]

			def initialize model, cols, val
				super model, cols, val[1]
				# sub: model, subquery, sub(condition)
				@cols.each {|col, sub| sub[ 1...1] = SmqlToAR.new( col.relation, val[0]).parse }
			end

			def verify_column col
				raise_unless col.child?, ConColumnError.new( [:Column], col)
			end

			def build builder, table
				@cols.each do |col, sub|
					t = table+col.to_a
					builder.sub_joins t, col, *sub[0..1]
					sub[2..-1].each &it.build( builder, t)
				end
				self
			end
		end

		Equal = simple_condition Condition, '=', "%s = %s", [Array, String, Numeric]
		Equal2 = simple_condition Equal, '', "%s = %s", [String, Numeric]
		GreaterThan = simple_condition Condition, '>', "%s > %s", [Array, Numeric]
		LesserThan = simple_condition Condition, '<', "%s < %s", [Array, Numeric]
		NotIlike = simple_condition Condition, '!~', "%s NOT ILIKE %s", [Array, String]
		Ilike = simple_condition Condition, '~', "%s ILIKE %s", [Array, String]
		Exists = simple_condition Condition, '', '%s IS NOT NULL', [true]
		NotExists = simple_condition Condition, '', '%s IS NULL', [false]

		Join = simple_condition EqualJoin, '', nil, [Hash]
		InRange2 = simple_condition InRange, '', nil, [Range]
		class Select < Condition
			Operator = ''
			Expected = [nil]

			def verify_column col
				raise_unless col.exist_in? || SmqlToAR.model_of( col.last_model, col.col), NonExistingSelectableError.new( col)
			end

			def build builder, table
				@cols.each do |col|
					if col.exist_in?
						col.joins builder, table
						builder.select table+col.to_a
					else
						col.joins {|j, m| builder.includes table+j }
						builder.includes table+col.to_a
					end
				end
				self
			end
		end

		class Functions < Condition
			Operator = ':'
			Expected = [String, Array, Hash, Numeric, nil]

			class Function
				include SmqlToAR::Assertion
				Name = nil
				Expected = []
				attr_reader :model, :func, :args

				class <<self
					def try_parse model, func, args
						SmqlToAR.logger.info( { try_parse: [func,args]}.inspect)
						self.new model, func, args  if self::Name === func and self::Expected.any?( &it === args)
					end

					def inspect
						"#{self.name}(:name=>#{self::Name}, :expected=>#{self::Expected})"
					end
				end

				def initialize model, func, args
					@model, @func, @args = model, func, args
				end
			end

			class Order < Function
				Name = :order
				Expected = [String, Array, Hash, nil]

				def initialize model, func, args
					args = case args
						when String then [args]
						when Array, Hash then args.to_a
						when nil then nil
						else raise 'Oops'
						end
					args.andand.collect! do |o|
						o = Array.wrap o
						col = Column.new model, o.first
						o = 'desc' == o.last.to_s.downcase ? :DESC : :ASC
						raise_unless col.exist_in?, NonExistingColumnError.new( [:Column], col)
						[col, o]
					end
					super model, func, args
				end

				def build builder, table
					return  if @args.blank?
					@args.each do |o|
						col, o = o
						col.joins builder, table
						t = table + col.path
						raise_unless 1 == t.length, RootOnlyFunctionError.new( t)
						builder.order t, col.col, o
					end
				end
			end

			class Limit < Function
				Name = :limit
				Expected = [Fixnum]

				def build builder, table
					raise_unless 1 == table.length, RootOnlyFunctionError.new( table)
					builder.limit @args
				end
			end

			class Offset < Function
				Name = :offset
				Expected = [Fixnum]

				def build builder, table
					raise_unless 1 == table.length, RootOnlyFunctionError.new( table)
					builder.offset @args
				end
			end

			def self.new model, col, val
				SmqlToAR.logger.info( { function: col.first.to_sym }.inspect)
				r = nil
				constants.each do |c|
					next  if [:Function, :Where, :Expected, :Operator].include? c
					c = const_get c
					next  if Function === c or not c.respond_to?( :try_parse)
					r = c.try_parse model, col.first.to_sym, val
					break  if r
				end
				r
			end
		end
	end
end
