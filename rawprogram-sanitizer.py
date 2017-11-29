#!/usr/bin/python

import struct, os, sys
import re
from types import *
import pprint
import operator
from xml.etree import ElementTree as ET
from collections import defaultdict

def usage():
    print("Usage: Combine rawprogram*.xml and patch*.xml into a single sanitized XML command file\n")

def main():

    db = defaultdict(list)
    patches = ET.Element("patches")
    programs = ET.Element("data")

    for arg in sys.argv[1:]:
        print("Processing file: " + arg)
        root = ET.parse(arg).getroot()

        for element in root:
            if element.tag == 'patch':
                patches.append(element)
            elif element.tag == 'program':
                if element.attrib['filename']:
                    programs.append(element)
            else:
                print("Unknown element: " + element.tag)

    tree = ET.ElementTree(patches)
    tree.write("patch.xml")
    tree = ET.ElementTree(programs)
    tree.write("rawprogram.xml")

if __name__ == "__main__":
    main()
