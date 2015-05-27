module Asciidoctor
module Prawn
module Extensions
  include ::Prawn::Measurements
  include ::Asciidoctor::Pdf::Sanitizer
  include ::Asciidoctor::PdfCore::PdfObject

  # - :height is the height of a line
  # - :leading is spacing between adjacent lines
  # - :padding_top is half line spacing, plus any line_gap in the font
  # - :padding_bottom is half line spacing
  # - :final_gap determines whether a gap is added below the last line
  LineMetrics = ::Struct.new :height, :leading, :padding_top, :padding_bottom, :final_gap

  # Core

  # Retrieves the catalog reference data for the PDF.
  #
  def catalog
    state.store.root
  end

  # Measurements

  # Returns the width of the current page from edge-to-edge
  #
  def page_width
    page.dimensions[2]
  end

  # Returns the height of the current page from edge-to-edge
  #
  def page_height
    page.dimensions[3]
  end

  # Returns the width of the left margin for the current page
  #
  def left_margin
    page.margins[:left]
  end

  # Returns the width of the right margin for the current page
  #
  def right_margin
    page.margins[:right]
  end

  # Returns whether the cursor is at the top of the page (i.e., margin box)
  #
  def at_page_top?
    @y == @margin_box.absolute_top
  end

  # Destinations

  # Generates a destination object that resolves to the top of the page
  # specified by the page_num parameter or the current page if no page number
  # is provided. The destination preserves the user's zoom level unlike
  # the destinations generated by the outline builder.
  #
  def dest_top page_num = nil
    dest_xyz 0, page_height, nil, (page_num ? state.pages[page_num - 1] : page)
  end

  # Text

=begin
  # Draws a disc bullet as float text
  def draw_bullet
    float { text '•' }
  end
=end

  # Fonts

  # Registers a new custom font described in the data parameter
  # after converting the font name to a String.
  #
  # Example:
  #
  #  register_font GillSans: {
  #    normal: 'assets/fonts/GillSans.ttf',
  #    bold: 'assets/fonts/GillSans-Bold.ttf',
  #    italic: 'assets/fonts/GillSans-Italic.ttf',
  #  }
  #  
  def register_font data
    font_families.update data.inject({}) {|accum, (key, val)| accum[key.to_s] = val; accum }
  end

  # Enhances the built-in font method to allow the font
  # size to be specified as the second option.
  #
  def font name = nil, options = {}
    if name && ::Numeric === options
      options = { size: options }
    end
    super name, options
  end

  # Retrieves the current font name (i.e., family).
  #
  def font_family
    font.options[:family]
  end

  alias :font_name :font_family

  # Retrieves the current font info (family, style, size) as a Hash
  #
  def font_info
    { family: font.options[:family], style: font.options[:style] || :normal, size: @font_size }
  end

  # Sets the font style for the scope of the block to which this method
  # yields. If the style is nil and no block is given, return the current 
  # font style.
  #
  def font_style style = nil
    if block_given?
      font font.options[:family], style: style do
        yield
      end
    elsif style
      font font.options[:family], style: style
    else
      font.options[:style] || :normal
    end
  end

  # Applies points as a scale factor of the current font if the value provided
  # is less than or equal to 1 or it's a string (e.g., 1.1em), then delegates to the super
  # implementation to carry out the built-in functionality.
  #
  #--
  # QUESTION should we round the result?
  def font_size points = nil
    return @font_size unless points
    #if points.is_a? String
    #  # QUESTION should we round?
    #  points = (@font_size * (points.chop.to_f / 100.0)).round
    #  warn points
    #elsif points <= 1
    #  points = (@font_size * points)
    #end
    if points <= 1
      points = (@font_size * points)
    end
    super points
  end

  def calc_line_metrics line_height = 1, font = self.font, font_size = self.font_size
    line_height_length = line_height * font_size
    leading = line_height_length - font_size
    half_leading = leading / 2
    padding_top = half_leading + font.line_gap
    padding_bottom = half_leading
    LineMetrics.new line_height_length, leading, padding_top, padding_bottom, false
  end

=begin
  # these line metrics attempted to figure out a correction based on the reported height and the font_size
  # however, it only works for some fonts, and breaks down for fonts like NotoSerif
  def calc_line_metrics line_height = 1, font = self.font, font_size = self.font_size
    line_height_length = font_size * line_height
    line_gap = line_height_length - font_size
    correction = font.height - font_size
    leading = line_gap - correction
    shift = (font.line_gap + correction + line_gap) / 2
    final_gap = font.line_gap != 0
    LineMetrics.new line_height_length, leading, shift, shift, final_gap
  end
=end

  # Parse the text into an array of fragments using the text formatter.
  def parse_text string, options = {}
    return [] if string.nil?

    options = options.dup
    if (format_option = options.delete :inline_format)
      format_option = [] unless format_option.is_a? ::Array
      fragments = self.text_formatter.format string, *format_option 
    else
      fragments = [{text: string}]
    end

    if (color = options.delete :color)
      fragments.map do |fragment|
        fragment[:color] ? fragment : fragment.merge(color: color)
      end
    else
      fragments
    end
  end

  # Performs the same work as text except that the first_line_options
  # are applied to the first line of text renderered.
  def text_with_formatted_first_line string, first_line_options, opts
    fragments = parse_text string, opts
    opts = opts.merge document: self
    box = ::Prawn::Text::Formatted::Box.new fragments, (opts.merge single_line: true)
    remaining_fragments = box.render dry_run: true
    # HACK prawn removes the color from remaining_fragments, so we have to explicitly restore
    if (color = opts[:color])
      remaining_fragments.each {|fragment| fragment[:color] ||= color }
    end
    # FIXME merge options more intelligently so as not to clobber other styles in set
    fragments = fragments.map {|fragment| fragment.merge first_line_options }
    fill_formatted_text_box fragments, (opts.merge single_line: true)
    if remaining_fragments.size > 0
      # as of Prawn 1.2.1, we have to handle the line gap after the first line manually
      move_down opts[:leading]
      remaining_fragments = fill_formatted_text_box remaining_fragments, opts
      draw_remaining_formatted_text_on_new_pages remaining_fragments, opts
    end
  end

  # Apply the text transform to the specified text.
  #
  # Supported transform values are "uppercase" or "lowercase" (passed as either
  # a String or a Symbol). When the uppercase transform is applied to the text,
  # it correctly uppercases visible text while leaving markup and named
  # character entities unchanged.
  #
  def transform_text text, transform
    case transform
    when :uppercase, 'uppercase'
      upcase_pcdata text
    when :lowercase, 'lowercase'
      text.downcase
    end
  end

  # Cursor

  # Short-circuits the call to the built-in move_up operation
  # when n is 0.
  #
  def move_up n
    super unless n == 0
  end

  # Short-circuits the call to the built-in move_down operation
  # when n is 0.
  #
  def move_down n
    super unless n == 0
  end

  # Bounds

  # Overrides the built-in pad operation to allow for asymmetric paddings.
  #
  # Example:
  #
  #  pad 20, 10 do
  #    text 'A paragraph with twice as much top padding as bottom padding.'
  #  end
  #
  def pad top, bottom = nil
    move_down top
    yield
    move_down(bottom || top)
  end

  # Combines the built-in pad and indent operations into a single method.
  #
  # Padding may be specified as an array of four values, or as a single value.
  # The single value is used as the padding around all four sides of the box.
  #
  # If padding is nil, this method simply yields to the block and returns.
  #
  # Example:
  #
  #  pad_box 20 do
  #    text 'A paragraph inside a blox with even padding on all sides.'
  #  end
  #
  #  pad_box [10, 10, 10, 20] do
  #    text 'An indented paragraph inside a box with equal padding on all sides.'
  #  end
  #
  def pad_box padding
    if padding
      # TODO implement shorthand combinations like in CSS
      p_top, p_right, p_bottom, p_left = (padding.is_a? ::Array) ? padding : ([padding] * 4)
      begin
        # inlined logic
        move_down p_top
        bounds.add_left_padding p_left
        bounds.add_right_padding p_right
        yield
        move_down p_bottom
      ensure
        bounds.subtract_left_padding p_left
        bounds.subtract_right_padding p_right
      end
    else
      yield
    end

    # alternate, delegated logic
    #pad padding[0], padding[2] do
    #  indent padding[1], padding[3] do
    #    yield
    #  end
    #end
  end

  # Stretch the current bounds to the left and right edges of the current page.
  #
  def use_page_width_if verdict
    if verdict
      indent(-bounds.absolute_left, bounds.absolute_right - page_width) do
        yield
      end
    else
      yield
    end
  end

  # Graphics

  # Fills the current bounding box with the specified fill color. Before
  # returning from this method, the original fill color on the document is
  # restored.
  def fill_bounds f_color = fill_color
    if f_color && f_color != 'transparent'
      prev_fill_color = fill_color
      fill_color f_color
      fill_rectangle bounds.top_left, bounds.width, bounds.height
      fill_color prev_fill_color
    end
  end

  # Fills the absolute bounding box with the specified fill color. Before
  # returning from this method, the original fill color on the document is
  # restored.
  def fill_absolute_bounds f_color = fill_color
    canvas { fill_bounds f_color }
  end

  # Fills the current bounds using the specified fill color and strokes the
  # bounds using the specified stroke color. Sets the line with if specified
  # in the options. Before returning from this method, the original fill
  # color, stroke color and line width on the document are restored.
  #
  def fill_and_stroke_bounds f_color = fill_color, s_color = stroke_color, options = {}
    no_fill = !f_color || f_color == 'transparent'
    no_stroke = !s_color || s_color == 'transparent'
    return if no_fill && no_stroke
    save_graphics_state do
      radius = options[:radius] || 0

      # fill
      unless no_fill
        fill_color f_color
        fill_rounded_rectangle bounds.top_left, bounds.width, bounds.height, radius
      end

      # stroke
      unless no_stroke
        stroke_color s_color
        line_width options[:line_width] || 0.5
        # FIXME think about best way to indicate dashed borders
        #if options.has_key? :dash_width
        #  dash options[:dash_width], space: options[:dash_space] || 1
        #end
        stroke_rounded_rectangle bounds.top_left, bounds.width, bounds.height, radius
        #undash if options.has_key? :dash_width
      end
    end
  end

  # Fills and, optionally, strokes the current bounds using the fill and
  # stroke color specified, then yields to the block. The only_if option can
  # be used to conditionally disable this behavior.
  #
  def shade_box color, line_color = nil, options = {}
    if (!options.has_key? :only_if) || options[:only_if]
      # FIXME could use save_graphics_state here
      previous_fill_color = current_fill_color
      fill_color color
      fill_rectangle [bounds.left, bounds.top], bounds.right, bounds.top - bounds.bottom
      fill_color previous_fill_color
      if line_color
        line_width 0.5
        previous_stroke_color = current_stroke_color
        stroke_color line_color
        stroke_bounds
        stroke_color previous_stroke_color
      end
    end
    yield
  end

  # A compliment to the stroke_horizontal_rule method, strokes a
  # vertical line using the current bounds. The width of the line
  # can be specified using the line_width option. The horizontal (x)
  # position can be specified using the at option.
  #
  def stroke_vertical_rule s_color = stroke_color, options = {}
    save_graphics_state do
      line_width options[:line_width] || 0.5
      stroke_color s_color
      stroke_vertical_line bounds.bottom, bounds.top, at: (options[:at] || 0)
    end
  end

  # Strokes a horizontal line using the current bounds. The width of the line
  # can be specified using the line_width option.
  #
  def stroke_horizontal_rule s_color = stroke_color, options = {}
    save_graphics_state do
      line_width options[:line_width] || 0.5
      stroke_color s_color
      stroke_horizontal_line bounds.left, bounds.right
    end
  end

  # Pages

  # Import the specified page into the current document.
  #
  def import_page file
    prev_page_number = page_number
    state.compress = false if state.compress # can't use compression if using template
    start_new_page_discretely template: file
    go_to_page prev_page_number + 1
  end

  # Create a new page for the specified image. If the
  # canvas option is true, the image is stretched to the
  # edges of the page (full coverage).
  def image_page file, options = {}
    start_new_page_discretely
    if options[:canvas]
      canvas do
        image file, width: bounds.width, height: bounds.height
      end
    else
      image file, fit: [bounds.width, bounds.height]
    end
    go_to_page page_count
  end

  # Perform an operation (such as creating a new page) without triggering the on_page_create callback
  #
  def perform_discretely
    if (saved_callback = state.on_page_create_callback)
      state.on_page_create_callback = nil
      yield
      state.on_page_create_callback = saved_callback
    else
      yield
    end
  end

  # Start a new page without triggering the on_page_create callback
  #
  def start_new_page_discretely options = {}
    perform_discretely do
      start_new_page options
    end
  end

  # Grouping

  # Conditional group operation
  #
  def group_if verdict
    if verdict
      state.optimize_objects = false # optimize objects breaks group
      group { yield }
    else
      yield
    end
  end

  def get_scratch_document
    # marshal if not using transaction feature
    #Marshal.load Marshal.dump @prototype

    # use cached instance, tests show it's faster
    #@prototype ||= ::Prawn::Document.new
    @scratch ||= if defined? @prototype
      scratch = Marshal.load Marshal.dump @prototype
      scratch.instance_variable_set(:@prototype, @prototype)
      # TODO set scratch number on scratch document
      scratch
    else
      warn 'asciidoctor: WARNING: no scratch prototype available; instantiating fresh scratch document'
      ::Prawn::Document.new
    end
  end

  def is_scratch?
    !!state.store.info.data[:Scratch]
  end
  alias :scratch? :is_scratch?

  # TODO document me
  def dry_run &block
    scratch = get_scratch_document
    scratch.start_new_page
    start_page_number = scratch.page_number
    start_y = scratch.y
    scratch.font font_family, style: font_style, size: font_size do
      scratch.instance_exec(&block)
    end
    whole_pages = scratch.page_number - start_page_number
    [(whole_pages * bounds.height + (start_y - scratch.y)), whole_pages, (start_y - scratch.y)]
  end

  # Attempt to keep the objects generated in the block on the same page
  #
  # TODO short-circuit nested usage
  def keep_together &block
    available_space = cursor
    total_height, _whole_pages, _remainder = dry_run(&block)
    # NOTE technically, if we're at the page top, we don't even need to do the
    # dry run, except several uses of this method rely on the calculated height
    if total_height > available_space && !at_page_top?
      start_new_page
      started_new_page = true
    else
      started_new_page = false
    end
    
    # HACK yield doesn't work here on JRuby (at least not when called from AsciidoctorJ)
    #yield remainder, started_new_page
    instance_exec(total_height, started_new_page, &block)
  end

  # Attempt to keep the objects generated in the block on the same page
  # if the verdict parameter is true.
  #
  def keep_together_if verdict, &block
    if verdict
      keep_together(&block)
    else
      yield
    end
  end

=begin
  def run_with_trial &block
    available_space = cursor
    whole_pages, remainder = dry_run(&block)
    if whole_pages > 0 || remainder > available_space
      started_new_page = true
    else
      started_new_page = false
    end
    # HACK yield doesn't work here on JRuby (at least not when called from AsciidoctorJ)
    #yield remainder, started_new_page
    instance_exec(remainder, started_new_page, &block)
  end
=end
end
end
end
