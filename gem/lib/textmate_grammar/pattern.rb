# frozen_string_literal: true

require 'deep_clone'
require 'yaml'
require 'textmate_grammar/grammar_plugin'
require 'textmate_grammar/util'

#
# Provides a base class to simplify the writing of complex regular expressions rules
# This class completely handles capture numbers and provides convenience methods for
# many common Regexp operations
#
class PatternBase
    # @return [PatternBase] The next pattern in the linked list of patterns
    attr_accessor :next_pattern
    # @return [String,PatternBase] The pattern to match
    attr_accessor :match
    # @return [Hash] The processed arguments
    attr_accessor :arguments
    # @return [Hash] The original arguments passed into initialize
    attr_accessor :original_arguments

    #
    # does @arguments contain any attributes that require this pattern be captured?
    #
    # @return [Boolean] if this PatternBase needs to capture
    #
    def needs_to_capture?
        capturing_attributes = [
            :tag_as,
            :reference,
            :includes,
        ]
        puts @match.class unless @arguments.is_a? Hash

        !(@arguments.keys & capturing_attributes).empty?
    end

    #
    # Can the capture be optimized out
    #
    # When the pattern has nothing after it then its capture can instead become
    # capture group 0
    #
    # @return [Boolean] can this capture become capture group 0
    #
    def optimize_outer_group?
        needs_to_capture? and @next_pattern.nil?
    end

    #
    # Appends pattern to the linked list of patterns
    #
    # @param [PatternBase] pattern the pattern to append
    #
    # @return [self]
    #
    # @see insert
    #
    def insert!(pattern)
        last = self
        last = last.next_pattern while last.next_pattern
        last.next_pattern = pattern
        self
    end

    #
    # Append pattern to a copy of the linked list of patterns
    #
    # @param [PatternBase] pattern the pattern to append
    #
    # @return [PatternBase] a copy of self with pattern appended
    #
    def insert(pattern)
        new_pattern = __deep_clone__
        new_pattern.insert!(pattern).freeze
    end

    #
    # Adds a capture group if needed
    #
    # @param [String] regex_as_string the pattern as a string
    #
    # @return [String] the pattern, potentially with a capture group
    #
    def add_capture_group_if_needed(regex_as_string)
        regex_as_string = "(#{regex_as_string})" if needs_to_capture?
        regex_as_string
    end

    #
    # Uses a block to transform all Patterns the list
    #
    # @yield [self] invokes the block with self for modification
    #
    # @return [self]
    #
    def map!(&block)
        yield self
        @match = @match.map!(&block) if @match.is_a? PatternBase
        @next_pattern = @next_pattern.map!(&block) if @next_pattern.is_a? PatternBase
        self
    end

    #
    # Uses block to recursively transform includes
    #
    # @yield [PatternBase,Symbol,Regexp,String] invokes the block with each include to transform
    #
    # @return [PatternBase] a copy of self with transformed includes
    #
    def transform_includes(&block)
        __deep_clone__.map! do |s|
            if s.arguments[:includes]
                if s.arguments[:includes].is_a? Array
                    s.arguments[:includes].map!(&block)
                else
                    s.arguments[:includes] = block.call s.arguments[:includes]
                end
            end
        end.freeze
    end

    #
    # Uses block to recursively transform tag_as
    #
    # @yield [String] Invokes the block to with each tag_as to transform
    #
    # @return [PatternBase] a copy of self with transformed tag_as
    #
    def transform_tag_as(&block)
        __deep_clone__.map! do |s|
            s.arguments[:tag_as] = block.call(s.arguments[:tag_as]) if s.arguments[:tag_as]
            next unless s.arguments[:includes].is_a?(Array)

            s.arguments[:includes].map! do |i|
                next i unless i.is_a? PatternBase

                i.transform_tag_as(&block)
            end
        end.freeze
    end

    #
    # Construct a new pattern
    #
    # @overload initialize(pattern)
    #   matches an exact pattern
    #   @param pattern [PatternBase, Regexp, String] the pattern to match
    # @overload initialize(opts)
    #   @param opts [Hash] options
    #   @option opts [PatternBase, Regexp, String] :match the pattern to match
    #   @option opts [String] :tag_as what to tag this pattern as
    #   @option opts [Array<PatternBase, Symbol>] :includes pattern includes
    #   @option opts [String] :reference a name for this pattern can be referred to in
    #       earlier or later parts of the pattern list, or in tag_as
    #   @option opts [Array<String>] :should_fully_match string that this pattern should
    #       fully match
    #   @option opts [Array<String>] :should_partial_match string that this pattern should
    #       partially match
    #   @option opts [Array<String>] :should_not_fully_match string that this pattern should
    #       not fully match
    #   @option opts [Array<String>] :should_not_partial_match string that this pattern should
    #       not partially match
    #   @option opts [Enumerator, Integer] :at_most match up to N times, nil to match any
    #       number of times
    #   @option opts [Enumerator, Integer] :at_least match no fewer than N times, nil to
    #       match any number of times
    #   @option opts [Enumerator, Integer] :how_many_times match exactly N times
    #   @option opts [Array<String>] :word_cannot_be_any_of list of wordlike string that
    #       the pattern should not match (this is a qualifier not a unit test)
    #   @option opts [Boolean] :dont_back_track? can this pattern backtrack
    #   @note Plugins may provide additional options
    #   @note all options except :match are optional
    # @overload initialize(opts, deep_clone, original)
    #   makes a copy of PatternBase
    #   @param opts [Hash] the original patterns @arguments with match
    #   @param deep_clone [:deep_clone] identifies as a deep_clone construction
    #   @param original [Hash] the original patterns @original_arguments
    #   @api private
    #   @note this should only be called by __deep_clone__, however subclasses must be
    #       able to accept this form
    #
    def initialize(*arguments)
        if arguments.length > 1 && arguments[1] == :deep_clone
            @arguments = arguments[0]
            @match = @arguments[:match]
            @arguments.delete(:match)
            @original_arguments = arguments[2]
            return
        end

        if arguments.length > 1
            # PatternBase was likely constructed like `PatternBase.new(/foo/, option: bar)`
            puts "PatternBase#new() expects a single Regexp, String, or Hash"
            puts "PatternBase#new() was provided with multiple arguments"
            puts "arguments:"
            puts arguments
            raise "See error above"
        end
        @next_pattern = nil
        arg1 = arguments[0]
        arg1 = {match: arg1} unless arg1.is_a? Hash
        @original_arguments = arg1.clone
        if arg1[:match].is_a? String
            arg1[:match] = Regexp.escape(arg1[:match]).gsub("/", "\\/")
            @match = arg1[:match]
        elsif arg1[:match].is_a? Regexp
            raise_if_regex_has_capture_group arg1[:match]
            @match = arg1[:match].inspect[1..-2] # convert to string and remove the slashes
        elsif arg1[:match].is_a? PatternBase
            @match = arg1[:match]
        else
            puts <<-HEREDOC.remove_indent
                Pattern.new() must be constructed with a String, Regexp, or Pattern
                Provided arguments: #{@original_arguments}
            HEREDOC
            raise "See error above"
        end
        arg1.delete(:match)
        @arguments = arg1
    end

    # attempts to provide a memorable name for a pattern
    # @return [String]
    def name
        return @arguments[:reference] unless @arguments[:reference].nil?
        return @arguments[:tag_as] unless @arguments[:tag_as].nil?

        to_s
    end

    #
    # converts a PatternBase to a Hash representing a textmate rule
    #
    # @return [Hash] The pattern as a textmate grammar rule
    #
    def to_tag
        output = {
            match: evaluate,
        }

        output[:captures] = convert_group_attributes_to_captures(collect_group_attributes)
        if optimize_outer_group?
            # optimize captures by removing outermost
            output[:match] = output[:match][1..-2]
            output[:name] = output[:captures]["0"][:name]
            output[:captures]["0"].delete(:name)
            output[:captures].reject! { |_, v| !v || v.empty? }
        end
        output.reject! { |_, v| !v || v.empty? }
        output
    end

    #
    # evaluates the pattern into a string suitable for inserting into a
    # grammar or constructing a Regexp.
    #
    # @param [Hash] groups if groups is nil consider this PatternBase to be the top_level
    #   when a pattern is top_level, group numbers and back references are relative
    #   to that pattern
    #
    # @return [String] the complete pattern
    #
    def evaluate(groups = nil)
        top_level = groups.nil?
        groups = collect_group_attributes if top_level
        self_evaluate = do_evaluate_self(groups)
        if @next_pattern.respond_to?(:integrate_pattern)
            single_entity = string_single_entity?(self_evaluate)
            self_evaluate = @next_pattern.integrate_pattern(self_evaluate, groups, single_entity)
        end
        self_evaluate = fixup_regex_references(groups, self_evaluate) if top_level
        self_evaluate
    end

    #
    # converts a pattern to a Regexp
    #
    # @param [Hash] groups if groups is nil consider this PatternBase to be the top_level
    #   when a pattern is top_level, group numbers and back references are relative
    #   to that pattern
    #
    # @return [Regexp] the pattern as a Regexp
    #
    def to_r(groups = nil)
        with_no_warnings { Regexp.new(evaluate(groups)) }
    end

    #
    # Displays the PatternBase as you would write it in code
    #
    # @param [Integer] depth the current nesting depth
    # @param [Boolean] top_level is this a top level pattern or is it being chained
    #
    # @return [String] The pattern as a string
    #
    def to_s(depth = 0, top_level = true)
        # TODO: make this method easier to understand

        # rubocop:disable Metrics/LineLength

        plugins = Grammar.plugins
        plugins.reject! { |p| (@original_arguments.keys & p.class.options).empty? }

        regex_as_string =
            case @original_arguments[:match]
            when PatternBase then @original_arguments[:match].to_s(depth + 2, true)
            when Regexp then @original_arguments[:match].inspect
            when String then "/" + Regexp.escape(@original_arguments[:match]) + "/"
            end
        indent = "  " * depth
        output = indent + do_get_to_s_name(top_level)
        # basic pattern information
        output += "\n#{indent}  match: " + regex_as_string.lstrip
        output += ",\n#{indent}  tag_as: \"" + @arguments[:tag_as] + '"' if @arguments[:tag_as]
        output += ",\n#{indent}  reference: \"" + @arguments[:reference] + '"' if @arguments[:reference]
        # unit tests
        output += ",\n#{indent}  should_fully_match: " + @arguments[:should_fully_match].to_s if @arguments[:should_fully_match]
        output += ",\n#{indent}  should_not_fully_match: " + @arguments[:should_not_fully_match].to_s if @arguments[:should_not_fully_match]
        output += ",\n#{indent}  should_partially_match: " + @arguments[:should_partially_match].to_s if @arguments[:should_partially_match]
        output += ",\n#{indent}  should_not_partially_match: " + @arguments[:should_not_partially_match].to_s if @arguments[:should_not_partially_match]

        output += ",\n#{indent}  includes: " + @arguments[:includes].to_s if @arguments[:includes]
        # add any linter/transform configurations
        plugins.each { |p| output += p.display_options(indent + "  ", @original_arguments) }
        # subclass, ending and recursive
        output += do_add_attributes(indent)
        output += ",\n#{indent})"
        output += @next_pattern.to_s(depth, false).lstrip if @next_pattern
        output
        # rubocop:enable Metrics/LineLength
    end

    #
    # Runs the unit tests, recursively
    #
    # @return [Boolean] If all test passed return true, otherwise false
    #
    def run_tests
        pass = [true]

        self_regex = @match.to_r
        warn = lambda do |symbol|
            puts <<-HEREDOC.remove_indent

                When testing the pattern #{self_regex.inspect}. The unit test for #{symbol} failed.
                The unit test has the following patterns:
                #{@arguments[symbol].to_yaml}
                The Failing pattern is below:
                #{self}
            HEREDOC
        end
        if @arguments[:should_fully_match].is_a? Array
            test_regex = with_no_warnings { /^(?:#{self_regex})$/ }
            if @arguments[:should_fully_match].all? { |test| test =~ test_regex } == false
                warn.call :should_fully_match
                pass << false
            end
        end
        if @arguments[:should_not_fully_match].is_a? Array
            test_regex = with_no_warnings { /^(?:#{self_regex})$/ }
            if @arguments[:should_not_fully_match].none? { |test| test =~ test_regex } == false
                warn.call :should_not_fully_match
                pass << false
            end
        end
        if @arguments[:should_partially_match].is_a? Array
            test_regex = self_regex
            if @arguments[:should_partially_match].all? { |test| test =~ test_regex } == false
                warn.call :should_partially_match
                pass << false
            end
        end
        if @arguments[:should_not_partially_match].is_a? Array
            test_regex = self_regex
            if @arguments[:should_not_partially_match].none? { |test| test =~ test_regex } == false
                warn.call :should_not_partially_match
                pass << false
            end
        end
        # run related unit tests
        pass << @match.run_tests if @match.is_a? PatternBase
        pass << @next_pattern.run_tests if @next_pattern.is_a? PatternBase
        if @arguments[:includes].is_a? Array
            @arguments[:includes]&.each { |inc| pass << inc.run_tests if inc.is_a? PatternBase }
        elsif @arguments[:includes].is_a? PatternBase
            pass << @arguments[:includes].run_tests
        end
        pass.none?(&:!)
    end

    #
    # To aid in Linters all Patterns support start_pattern which return the pattern
    # for initial match, for a single match pattern that is itself
    #
    # @return [self] This pattern
    #
    def start_pattern
        self
    end

    #
    # Gets the patterns Hashcode
    #
    # @return [Integer] the Hashcode
    #
    def hash
        # TODO: find a better hash code
        # PatternBase.new("abc") == PatternBase.new(PatternBase.new("abc"))
        # but PatternBase.new("abc").hash != PatternBase.new(PatternBase.new("abc")).hash
        @match.hash
    end

    #
    # Checks for equality
    # A pattern is considered equal to another pattern if the result of tag_as is equivalent
    #
    # @param [PatternBase] other the pattern to compare
    #
    # @return [Boolean] true if other is a PatternBase and to_tag is equivalent, false otherwise
    #
    def eql?(other)
        return false unless other.is_a? PatternBase

        to_tag == other.to_tag
    end

    # (see eql?)
    def ==(other)
        eql? other
    end

    #
    # Construct a new pattern and append to the end
    #
    # @param [PatternBase] pattern options (see #initialize for options)
    # @see #initialize
    #
    # @return [PatternBase] a copy of self with a pattern inserted
    #
    def then(pattern)
        pattern = PatternBase.new(pattern) unless pattern.is_a? PatternBase
        insert(pattern)
    end
    # other methods added by subclasses

    #
    # evaluates @match
    # @note optionally override when inheriting
    # @note by default this adds quantifier options and optionally adds a capture group
    #
    # @param [Hash] groups group attributes
    #
    # @return [String] the result of evaluating @match
    #
    def do_evaluate_self(groups)
        match = @match
        match = match.evaluate(groups) if match.is_a? PatternBase
        add_capture_group_if_needed(match)
    end

    #
    # Combines self with with the result of evaluate on the previous pattern
    #
    # @note optionally override when inheriting if concatenation is not sufficient
    #
    # @param [String] previous the result of evaluate on the previous pattern
    #   in the linked list of patterns
    # @param [Array] groups group attributes
    # @param [Boolean] single_entity is previous a single entity
    #
    # @return [String] the combined regexp
    #
    def integrate_pattern(previous, groups, single_entity) # rubocop:disable UnusedMethodArgument
        # by default just concat the groups
        "#{previous}#{evaluate(groups)}"
    end

    #
    # return a string of any additional attributes that need to be added to the #to_s output
    # indent is a string with the amount of space the parent block is indented, attributes
    # are indented 2 more spaces
    # called by #to_s
    #
    # @param [String] indent the spaces to indent with
    #
    # @return [String] the attributes to add
    #
    def do_add_attributes(indent) # rubocop:disable Lint/UnusedMethodArgument
        ""
    end

    #
    # What is the name of the method that the user would call
    # top_level is if a freestanding or chaining function is called
    # called by #to_s
    #
    # @param [Boolean] top_level is this top_level or chained
    #
    # @return [String] the name of the method
    #
    def do_get_to_s_name(top_level)
        top_level ? "Pattern.new(" : ".then("
    end

    # (see string_single_entity)
    def single_entity?
        string_single_entity? evaluate
    end

    # does this pattern contain no capturing groups
    def groupless?
        collect_group_attributes == []
    end

    # create a copy of this pattern that contains no groups
    # @return [PatternBase]
    def groupless
        __deep_clone__.map! do |s|
            s.arguments.delete(:tag_as)
            s.arguments.delete(:reference)
            s.arguments.delete(:includes)
            raise "unable to remove capture" if s.needs_to_capture?
        end.freeze
    end

    #
    # Retags all tags_as
    #
    # @param [Hash] args retag options
    # @option [Boolean] :all (true) should all tags be kept
    # @option [Boolean] :keep (true) should all tags be kept
    # @option [String] :append a string to append to all tags (implies :keep)
    # @option [String] tag_as maps from an old tag_as to a new tag_as
    # @option [String] reference maps from reference to a new tag_as
    #
    # @return [PatternBase] a copy of self retagged
    #
    def reTag(args)
        __deep_clone__.map! do |s|
            # tags are keep unless `all: false` or `keep: false`, and append is not a string
            discard_tag = (args[:all] == false || args[:keep] == false)
            discard_tag = false if args[:append].is_a? String

            args.each do |key, tag|
                if [s.arguments[:tag_as], s.arguments[:reference]].include? key
                    s.arguments[:tag_as] = tag
                    discard_tag = false
                end
            end

            if args[:append].is_a?(String) && s.arguments[:tag_as]
                s.arguments[:tag_as] = s.arguments[:tag_as] + "." + args[:append]
            end

            s.arguments.delete(:tag_as) if discard_tag
        end.freeze
    end

    #
    # Collects information about the capture groups
    #
    # @api private
    #
    # @param [Integer] next_group the next group number to use
    #
    # @return [Array<Hash>] group attributes
    #
    def collect_group_attributes(next_group = optimize_outer_group? ? 0 : 1)
        groups = do_collect_self_groups(next_group)
        next_group += groups.length
        if @match.is_a? PatternBase
            new_groups = @match.collect_group_attributes(next_group)
            groups.concat(new_groups)
            next_group += new_groups.length
        end
        if @next_pattern.is_a? PatternBase
            new_groups = @next_pattern.collect_group_attributes(next_group)
            groups.concat(new_groups)
        end
        groups
    end

    #
    # Collect group information about self
    #
    # @param [Integer] next_group The next group number to use
    #
    # @return [Array<Hash>] group attributes
    #
    def do_collect_self_groups(next_group)
        groups = []
        groups << {group: next_group}.merge(@arguments) if needs_to_capture?
        groups
    end

    #
    # Displays the Pattern for inspection
    #
    # @return [String] A representation of the pattern
    #
    def inspect
        super.split(" ")[0] + " match:" + @match.inspect
    end

    #
    # Convert group references into backreferences
    #
    # @api private
    #
    # @param [Hash] groups group information for the pattern
    # @param [String] self_regex the pattern as string
    #
    # @return [String] the fixed up regex_string
    #
    def fixup_regex_references(groups, self_regex)
        # rubocop:disable Metrics/LineLength
        references = {}
        # convert all references to group numbers
        groups.each do |group|
            references[group[:reference]] = group[:group] unless group[:reference].nil?
        end

        # convert back references
        self_regex = self_regex.gsub(/\(\?\#\[:backreference:([^\\]+?):\]\)/) do
            match_reference = Regexp.last_match(1)
            if references[match_reference].nil?
                raise "\nWhen processing the matchResultOf:#{match_reference}, I couldn't find the group it was referencing"
            end

            # if the reference does exist, then replace it with it's number
            "\\#{references[match_reference]}"
        end

        # check for a subroutine to the Nth group, replace it with `\N`
        self_regex = self_regex.gsub(/\(\?\#\[:subroutine:([^\\]+?):\]\)/) do
            match_reference = Regexp.last_match(1)
            if references[match_reference].nil?
                raise "\nWhen processing the recursivelyMatch:#{match_reference}, I couldn't find the group it was referencing"
            end

            # if the reference does exist, then replace it with it's number
            "\\g<#{references[match_reference]}>"
        end
        # rubocop:enable Metrics/LineLength
        self_regex
    end

    #
    # Converts group attributes into a captures hash
    #
    # @api private
    #
    # @param [Hash] groups group attributes
    #
    # @return [Hash] capture hash
    #
    def convert_group_attributes_to_captures(groups)
        captures = {}

        groups.each do |group|
            output = {}
            output[:name] = group[:tag_as] unless group[:tag_as].nil?
            if group[:includes].is_a? Array
                output[:patterns] = convert_includes_to_patterns(group[:includes])
            elsif !group[:includes].nil?
                output[:patterns] = convert_includes_to_patterns([group[:includes]])
            end
            captures[group[:group].to_s] = output
        end
        # replace $match and $reference() with the appropriate capture number
        captures.each do |key, value|
            next if value[:name].nil?

            value[:name] = value[:name].gsub(/\$(?:match|reference\((.+)\))/) do |match|
                next ("$" + key) if match == "$match"

                reference_group = groups.detect do |group|
                    group[:reference] == Regexp.last_match(1)
                end
                "$" + reference_group[:group].to_s
            end
        end
    end

    #
    # converts an includes array into a patterns array
    #
    # @api private
    #
    # @param [Array<PatternBase, Symbol>] includes an includes array
    #
    # @return [Array<Hash>] a patterns array
    #
    def convert_includes_to_patterns(includes)
        includes = [includes] unless includes.is_a? Array
        patterns = includes.flatten.map do |rule|
            next rule if rule.is_a?(String) && rule.start_with?("source.", "text.")
            next "$self" if rule == :$self
            next "$base" if rule == :$base
            next {include: "##{rule}"} if rule.is_a? Symbol

            rule = PatternBase.new(rule) unless rule.is_a? PatternBase
            rule.to_tag
        end
        patterns
    end

    #
    # Deeply clone self
    #
    # @return [PatternBase] a copy of self
    #
    def __deep_clone__
        options = @arguments.__deep_clone__
        options[:match] = @match.__deep_clone__
        new_pattern = self.class.new(options, :deep_clone, @original_arguments)
        new_pattern.insert! @next_pattern.__deep_clone__
    end

    #
    # Raise an error if regex contains a capturing group
    #
    # @param [Regexp] regex the regexp to test
    # @param [Integer] check the group to check for
    #
    # @return [void]
    #
    def raise_if_regex_has_capture_group(regex, check = 1)
        # this will throw a RegexpError if there are no capturing groups
        _ignore = /#{regex}#{"\\" + check.to_s}/
        # at this point @match contains a capture group, complain
        raise <<-HEREDOC.remove_indent

            There is a pattern that is being constructed from a regular expression
            with a capturing group. This is not allowed, as the group cannot be tracked
            The bad pattern is
            #{self}
        HEREDOC
    rescue RegexpError # rubocop: disable Lint/HandleExceptions
        # no capture groups present, purposely do nothing
    end
end

class Pattern < PatternBase
    # @return [Integer,nil] the minimum amount that can be matched
    attr_accessor :at_least
    # @return [Integer,nil] the maximum amount that can be matched
    attr_accessor :at_most
    # (see PatternBase#initialize)
    def initialize(*arguments)
        super(*arguments)

        @at_least = nil
        @at_most = nil
        process_quantifiers_from_arguments
    end

    #
    # sets @at_least and @at_most based on arguments
    #
    # @return [void]
    #
    # @api private
    #
    def process_quantifiers_from_arguments
        # this sets the @at_most and @at_least value based on the arguments

        #
        # Simplify the quantity down to just :at_least and :at_most
        #
        attributes_clone = @arguments.clone
        # convert Enumerators to numbers
        [:at_least, :at_most, :how_many_times?].each do |each|
            if attributes_clone[each].is_a?(Enumerator)
                attributes_clone[each] = attributes_clone[each].size
            end
        end

        # canonize dont_back_track? and as_few_as_possible?
        @arguments[:dont_back_track?] ||= @arguments[:possessive?]
        @arguments[:as_few_as_possible?] ||= @arguments[:lazy?]
        if @arguments[:greedy?]
            @arguments[:dont_back_track?] = false
            @arguments[:as_few_as_possible?] = false
        end
        # extract the data
        at_least       = attributes_clone[:at_least]
        at_most        = attributes_clone[:at_most]
        how_many_times = attributes_clone[:how_many_times?]
        # simplify to at_least and at_most
        at_least = at_most = how_many_times if how_many_times.is_a?(Integer)

        # check if quantifying is allowed
        # check after everything else in case additional quantifying options
        # are created in the future
        if quantifying_allowed?
            @at_least = at_least
            @at_most = at_most
        # if a quantifying value was set and quantifying is not allowed, raise an error
        # telling the user that its not allowed
        elsif !(at_most.nil? && at_least.nil?)
            raise <<-HEREDOC.remove_indent

                Inside of the #{name} pattern, there are some quantity arguments like:
                    :at_least
                    :at_most
                    or :how_many_times?
                These are not allowed in this kind of #{do_get_to_s_name}) pattern
                If you did this intentionally please wrap it inside of a Pattern.new()
                ex: #{do_get_to_s_name} Pattern.new( *your_arguments* ) )
            HEREDOC
        end

        return unless @arguments[:dont_back_track?] && @arguments[:as_few_as_possible?]

        raise ":dont_back_track? and :as_few_as_possible? cannot both be provided"
    end

    #
    # converts @at_least and @at_most into the appropriate quantifier
    # this is a simple_quantifier because it does not include atomic-ness
    #
    # @return [String] the quantifier
    #
    def simple_quantifier
        # Generate the ending based on :at_least and :at_most

        # by default assume no quantifiers
        quantifier = ""
        # if there is no at_least, at_most, or how_many_times, then theres no quantifier
        if @at_least.nil? and @at_most.nil?
            quantifier = ""
        # if there is a quantifier
        else
            # if there's no at_least, then assume at_least = 1
            @at_least = 1 if @at_least.nil?

            quantifier =
                if @at_least == 1 and @at_most == 1
                    # no qualifier
                    ""
                elsif @at_least == 0 and @at_most == 1
                    # this is just a different way of "maybe"
                    "?"
                elsif @at_least == 0 and @at_most.nil?
                    # this is just a different way of "zeroOrMoreOf"
                    "*"
                elsif @at_least == 1 and @at_most.nil?
                    # this is just a different way of "oneOrMoreOf"
                    "+"
                elsif @at_least == @most
                    # exactly N times
                    "{#{@at_least}}"
                else
                    # if it is more complicated than that, just use a range
                    "{#{@at_least},#{@at_most}}"
                end
        end
        # quantifiers can be made possessive without requiring atomic groups
        quantifier += "+" if quantifier != "" && @arguments[:dont_back_track?] == true
        quantifier += "?" if quantifier != "" && @arguments[:as_few_as_possible?] == true
        quantifier
    end

    #
    # Adds quantifiers to match
    #
    # @param [String, PatternBase] match the pattern to add a quantifier to
    # @param [Array] groups group information, used for evaluating match
    #
    # @return [String] match with quantifiers applied
    #
    def add_quantifier_options_to(match, groups)
        match = match.evaluate(groups) if match.is_a? PatternBase
        quantifier = simple_quantifier
        # check if there are quantifiers
        if quantifier != ""
            # if the match is not a single entity, then it needs to be wrapped
            match = "(?:#{match})" unless string_single_entity?(match)
            # add the quantified ending
            match += quantifier
        elsif @arguments[:dont_back_track?] == true
            # make atomic, which allows arbitrary expression to be prevented from backtracking
            match = "(?>#{match})"
        end
        if @arguments[:word_cannot_be_any_of]
            word_pattern = @arguments[:word_cannot_be_any_of].map { |w| Regexp.escape w }.join "|"
            match = "(?!\\b(?:#{word_pattern})\\b)#{match}"
        end
        match
    end

    # (see PatternBase#do_evaluate_self)
    def do_evaluate_self(groups)
        add_capture_group_if_needed(add_quantifier_options_to(@match, groups))
    end

    # controls weather @arguments[:at_most] et. al. set @at_most et. al.
    # @note override when inheriting. Return false unless the subclass allow quantifying
    # @return [Boolean] if quantifying is allowed
    # @note the default implementation returns True
    def quantifying_allowed?
        true
    end

    #
    # (see #PatternBase#do_add_attributes)
    #
    def do_add_attributes(indent)
        # rubocop:disable Metrics/LineLength
        output = ""
        # special #then arguments
        if quantifying_allowed?
            output += ",\n#{indent}  at_least: " + @arguments[:at_least].to_s if @arguments[:at_least]
            output += ",\n#{indent}  at_most: " + @arguments[:at_most].to_s if @arguments[:at_most]
            output += ",\n#{indent}  how_many_times: " + @arguments[:how_many_times].to_s if @arguments[:how_many_times]
            output += ",\n#{indent}  word_cannot_be_any_of: " + @arguments[:word_cannot_be_any_of].to_s if @arguments[:word_cannot_be_any_of]
        end
        output += ",\n#{indent}  dont_back_track?: " + @arguments[:dont_back_track?].to_s if @arguments[:dont_back_track?]
        output
        # rubocop:enable Metrics/LineLength
    end
end