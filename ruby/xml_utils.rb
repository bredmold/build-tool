module XmlUtils
  def element_text(element, name, default_value)
    sub_elements = element.elements.each(name) { |e| e }
    if sub_elements.first
      sub_elements.first.text
    elsif !sub_elements.first && default_value
      default_value
    else
      raise "Unable to find #{name} in #{element.name}"
    end
  end
end