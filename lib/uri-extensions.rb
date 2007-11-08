# curl-multi - Ruby bindings for the libcurl multi interface
# Copyright (C) 2007 Philotic, Inc.

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

require 'uri'

module URI
  # Fully escape the web parameters
  def self.fully_escape(uri)
    self.escape(uri, Regexp.new("[^#{URI::PATTERN::UNRESERVED}]"))
  end

  def self.escaped_params_array(params)
    params.map{|k,v| fully_escape(k.to_s) + '=' + fully_escape(v.to_s)}
  end

  # This returns a URL-encoded string suitable for use as a POST body or for
  # pasting into a URL.
  def self.escape_params(params)
    escaped_params_array(params).join('&')
  end
end
