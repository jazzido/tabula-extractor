module Tabula

  class ZoneEntity
    attr_accessor :top, :left, :width, :height

    attr_accessor :texts

    def initialize(top, left, width, height)
      self.top = top
      self.left = left
      self.width = width
      self.height = height
      self.texts = []
    end

    def bottom
      self.top + self.height
    end

    def right
      self.left + self.width
    end

    # [x, y]
    def midpoint
      [self.left + (self.width / 2), self.top + (self.height / 2)]
    end

    def area
      self.width * self.height
    end

    def merge!(other)
      self.top    = [self.top, other.top].min
      self.left   = [self.left, other.left].min
      self.width  = [self.right, other.right].max - left
      self.height = [self.bottom, other.bottom].max - top
    end

    def horizontal_distance(other)
      (other.left - self.right).abs
    end

    def vertical_distance(other)
      (other.bottom - self.bottom).abs
    end

    # Roughly, detects if self and other belong to the same line
    def vertically_overlaps?(other)
      vertical_overlap = [0, [self.bottom, other.bottom].min - [self.top, other.top].max].max
      vertical_overlap > 0
    end

    # detects if self and other belong to the same column
    def horizontally_overlaps?(other)
      horizontal_overlap = [0, [self.right, other.right].min  - [self.left, other.left].max].max
      horizontal_overlap > 0
    end

    def overlaps?(other, ratio_tolerance=0.00001)
      self.overlap_ratio(other) > ratio_tolerance
    end

    def overlap_ratio(other)
      intersection_width = [0, [self.right, other.right].min  - [self.left, other.left].max].max
      intersection_height = [0, [self.bottom, other.bottom].min - [self.top, other.top].max].max
      intersection_area = [0, intersection_height * intersection_width].max

      union_area = self.area + other.area - intersection_area
      intersection_area / union_area
    end

    def to_h
      hash = {}
      [:top, :left, :width, :height].each do |m|
        hash[m] = self.send(m)
      end
      hash
    end

    def to_json(options={})
      self.to_h.to_json
    end
  end

  class Page < ZoneEntity
    attr_reader :rotation, :number

    def initialize(width, height, rotation, number, texts=[])
      super(0, 0, width, height)
      @rotation = rotation
      @number = number
      self.texts = texts
    end

    # get text, optionally from a provided area in the page [top, left, bottom, right]
    def get_text(area=nil)
      area = [0, 0, width, height] if area.nil?

      # spaces are not detected, b/c they have height == 0
      # ze = ZoneEntity.new(area[0], area[1], area[3] - area[1], area[2] - area[0])
      # self.texts.select { |t| t.overlaps? ze } 
      self.texts.select { |t| 
        t.top > area[0] && t.top + t.height < area[2] && t.left > area[1] && t.left + t.width < area[3]
      }
    end

    def to_json(options={})
      { :width => self.width,
        :height => self.height,
        :number => self.number,
        :rotation => self.rotation,
        :texts => self.texts
      }.to_json(options)
    end

  end

  class TextElement < ZoneEntity
    attr_accessor :font, :font_size, :text, :width_of_space

    CHARACTER_DISTANCE_THRESHOLD = 1.5
    TOLERANCE_FACTOR = 0.25

    def initialize(top, left, width, height, font, font_size, text, width_of_space)
      super(top, left, width, height)
      self.font = font
      self.font_size = font_size
      self.text = text
      self.width_of_space = width_of_space
    end

    # more or less returns True if distance < tolerance
    def should_merge?(other)
      raise TypeError, "argument is not a TextElement" unless other.instance_of?(TextElement)
      overlaps = self.vertically_overlaps?(other)

      tolerance = ((self.font_size + other.font_size) / 2) * TOLERANCE_FACTOR

      overlaps or
        (self.height == 0 and other.height != 0) or
        (other.height == 0 and self.height != 0) and
        self.horizontal_distance(other) < tolerance
    end

    # more or less returns True if (tolerance <= distance < CHARACTER_DISTANCE_THRESHOLD*tolerance)
    def should_add_space?(other)
      raise TypeError, "argument is not a TextElement" unless other.instance_of?(TextElement)
      overlaps = self.vertically_overlaps?(other)

      up_tolerance = ((self.font_size + other.font_size) / 2) * TOLERANCE_FACTOR
      down_tolerance = 0.95

      dist = self.horizontal_distance(other).abs
      
      rv = overlaps && (dist.between?(self.width_of_space * down_tolerance, self.width_of_space + up_tolerance))
      rv
    end

    def merge!(other)
      raise TypeError, "argument is not a TextElement" unless other.instance_of?(TextElement)
      # unless self.horizontally_overlaps?(other) or self.vertically_overlaps?(other)
      #   raise ArgumentError, "won't merge TextElements that don't overlap"
      # end
      if self.horizontally_overlaps?(other) and other.top < self.top
        self.text = other.text + self.text
      else
        self.text << other.text
      end
      super(other)
    end

    def to_h
      hash = super
      [:font, :text].each do |m|
        hash[m] = self.send(m)
      end
      hash
    end
  end


  class Line < ZoneEntity
    attr_accessor :text_elements

    def initialize
      self.text_elements = []
    end

    def <<(t)
      if self.text_elements.size == 0
        self.text_elements << t
        self.top = t.top
        self.left = t.left
        self.width = t.width
        self.height = t.height
      else
        if in_same_column = self.text_elements.find { |te| te.horizontally_overlaps?(t) }
          in_same_column.merge!(t)
        else
          self.text_elements << t
          self.merge!(t)
        end
      end
    end


  end

  class Column < ZoneEntity
    attr_accessor :text_elements

    def initialize(left, width, text_elements=[])
      super(0, left, width, 0)
      @text_elements = text_elements
    end

    def <<(te)
      self.text_elements << te
      self.update_boundaries!(te)
      self.text_elements.sort_by! { |t| t.top }
    end

    def update_boundaries!(text_element)
      self.merge!(text_element)
    end

    # this column can be merged with other_column?
    def contains?(other_column)
      self.horizontally_overlaps?(other_column)
    end

    def average_line_distance
      # avg distance between lines
      # this might help to MERGE lines that are shouldn't be split
      # e.g. cells with > 1 lines of text
      1.upto(self.text_elements.size - 1).map { |i|
        self.text_elements[i].top - self.text_elements[i - 1].top
      }.inject{ |sum, el| sum + el }.to_f / self.text_elements.size
    end

    def inspect
      vars = (self.instance_variables - [:@text_elements]).map{ |v| "#{v}=#{instance_variable_get(v).inspect}" }
      texts = self.text_elements.sort_by { |te| te.top }.map { |te| te.text }
      "<#{self.class}: #{vars.join(', ')}, @text_elements=[#{texts.join('], [')}]>"
    end

  end

  class Ruling < ZoneEntity
    attr_accessor :color

    def initialize(top, left, width, height, color)
      super(top, left, width, height)
      self.color = color
    end

    def to_h
      hash = super
      hash[:color] = self.color
      hash
    end

  end

end
